# ===------------------------------------------------------------------------=== #
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License version 3 as
#  published by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
#  License for more details.
#
#  You should have received a copy of the GNU Lesser General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
# ===------------------------------------------------------------------------=== #

from std.atomic import Atomic, Ordering, fence
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys.info import size_of

# Cache-line padding keeps the independently modified top and bottom indexes from sharing a cache line
struct PaddedAtomicI64:
    comptime CACHE_LINE_SIZE_BYTES = 64
    comptime PAD_BYTES = Self.CACHE_LINE_SIZE_BYTES - size_of[Atomic[DType.int64]]()
    var atomic_value: Atomic[DType.int64]
    var padding: Array[UInt8, Self.PAD_BYTES]

    # constructor
    def __init__(out self, initial: Int64):
        self.atomic_value = Atomic[DType.int64](initial)
        self.padding = Array[UInt8, Self.PAD_BYTES](uninitialized=True)

# Result returned by pop_bottom and steal_top
struct WorkStealResult(ImplicitlyCopyable):
    comptime SUCCESS: UInt8 = 0
    comptime EMPTY: UInt8 = 1
    comptime RETRY: UInt8 = 2
    var status: UInt8
    var actor_id: Int64

    # constructor
    def __init__(out self, status: UInt8, actor_id: Int64 = -1):
        self.status = status
        self.actor_id = actor_id

    # create a SUCCESS result with the given actor ID
    @staticmethod
    def success(actor_id: Int64) -> WorkStealResult:
        return WorkStealResult(WorkStealResult.SUCCESS, actor_id)

    # create an EMPTY result
    @staticmethod
    def empty() -> WorkStealResult:
        return WorkStealResult(WorkStealResult.EMPTY)

    # create a RETRY result
    @staticmethod
    def retry() -> WorkStealResult:
        return WorkStealResult(WorkStealResult.RETRY)

    # check if the result is a SUCCESS
    @always_inline
    def is_success(self) -> Bool:
        return self.status == Self.SUCCESS

# Fixed-capacity Chase-Lev work-stealing deque
struct WorkStealingDeque(Movable):
    var buffer: Pointer[Atomic[DType.int64], MutUntrackedOrigin]
    var capacity: Int64
    var mask: Int64
    var top: PaddedAtomicI64
    var bottom: PaddedAtomicI64

    # constructor
    def __init__(out self, capacity: Int) raises:
        if capacity < 2 or (capacity & (capacity - 1)) != 0:
            raise Error("WorkStealingDeque capacity must be a power of two and at least 2")
        self.capacity = Int64(capacity)
        self.mask = Int64(capacity - 1)
        self.buffer = unsafe_alloc[Atomic[DType.int64]](capacity)
        self.top = PaddedAtomicI64(0)
        self.bottom = PaddedAtomicI64(0)
        for i in range(capacity):
            self.buffer.unsafe_offset(i)[] = Atomic[DType.int64](-1)

    # move constructor
    def __init__(out self, *, deinit move: Self):
        self.buffer = move.buffer
        self.capacity = move.capacity
        self.mask = move.mask
        self.top = PaddedAtomicI64(move.top.atomic_value.load[ordering=Ordering.RELAXED]())
        self.bottom = PaddedAtomicI64(move.bottom.atomic_value.load[ordering=Ordering.RELAXED]())

    # destructor
    def __deinit__(deinit self):
        for i in range(Int(self.capacity)):
            self.buffer.unsafe_offset(i).unsafe_deinit_pointee()
        self.buffer.unsafe_free()

    # load an actor ID from the buffer
    @always_inline
    def _load_slot(self, logical_index: Int64) -> Int64:
        var slot_index = Int(logical_index & self.mask)
        return self.buffer.unsafe_offset(slot_index)[].load[ordering=Ordering.RELAXED]()

    # store an actor ID in the buffer
    @always_inline
    def _store_slot(mut self, logical_index: Int64, actor_id: Int64):
        var slot_index = Int(logical_index & self.mask)
        Atomic[DType.int64].store[ordering=Ordering.RELAXED](Pointer(to=self.buffer.unsafe_offset(slot_index)[].value), actor_id)

    # update on the top index
    @always_inline
    def _store_top(mut self, value: Int64):
        Atomic[DType.int64].store[ordering=Ordering.RELAXED](Pointer(to=self.top.atomic_value.value), value)

    # update on the bottom index
    @always_inline
    def _store_bottom(mut self, value: Int64):
        Atomic[DType.int64].store[ordering=Ordering.RELAXED](Pointer(to=self.bottom.atomic_value.value), value)

    # returns false when the fixed-capacity deque is full (owner-only)
    def push_bottom(mut self, actor_id: Int64) -> Bool:
        var b = self.bottom.atomic_value.load[ordering=Ordering.RELAXED]()
        var t = self.top.atomic_value.load[ordering=Ordering.ACQUIRE]()
        # leave one slot unused, matching the bounded Chase-Lev invariant
        if b - t >= self.capacity - 1:
            return False
        self._store_slot(b, actor_id)
        fence[ordering=Ordering.RELEASE]()
        self._store_bottom(b + 1)
        return True

    # local work is consumed in LIFO order (owner-only)
    def pop_bottom(mut self) -> WorkStealResult:
        var b = self.bottom.atomic_value.load[ordering=Ordering.RELAXED]() - 1
        self._store_bottom(b)
        fence[ordering=Ordering.SEQUENTIAL]()
        var t = self.top.atomic_value.load[ordering=Ordering.RELAXED]()
        if t > b:  # empty
            self._store_bottom(t)
            return WorkStealResult.empty()
        var actor_id = self._load_slot(b)
        if t < b:  # more than one input
            return WorkStealResult.success(actor_id)
        # the owner and thieves race through top for the final item
        var expected = t
        if not self.top.atomic_value.compare_exchange[
            success_ordering=Ordering.SEQUENTIAL,
            failure_ordering=Ordering.RELAXED]
            (expected, t + 1):
            self._store_bottom(t + 1)
            return WorkStealResult.empty()
        self._store_bottom(t + 1)
        return WorkStealResult.success(actor_id)

    # stolen work is consumed in FIFO order
    def steal_top(mut self) -> WorkStealResult:
        var t = self.top.atomic_value.load[ordering=Ordering.ACQUIRE]()
        fence[ordering=Ordering.SEQUENTIAL]()
        var b = self.bottom.atomic_value.load[ordering=Ordering.ACQUIRE]()
        if t >= b:
            return WorkStealResult.empty()
        var actor_id = self._load_slot(t)
        var expected = t
        if not self.top.atomic_value.compare_exchange[
            success_ordering=Ordering.SEQUENTIAL,
            failure_ordering=Ordering.RELAXED]
            (expected, t + 1):
            return WorkStealResult.retry()
        return WorkStealResult.success(actor_id)

    # approximate under concurrent stealing; exact for the owner in isolation
    def size(self) -> Int:
        var b = self.bottom.atomic_value.load[ordering=Ordering.ACQUIRE]()
        var t = self.top.atomic_value.load[ordering=Ordering.ACQUIRE]()
        if b <= t:
            return 0
        return Int(b - t)
