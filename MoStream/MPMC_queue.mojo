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
from std.time import sleep
from std.sys.info import size_of
from std.collections import Optional
from std.sys.terminate import exit
from MoStream.utils import print_red_color

# Struct to add padding to an atomic variable to avoid false sharing between producer and consumer
struct PaddedAtomicU64:
    comptime CACHE_LINE_SIZE_BYTES = 64
    comptime PAD_BYTES = Self.CACHE_LINE_SIZE_BYTES - size_of[Atomic[DType.uint64]]()
    var atomicVal: Atomic[DType.uint64]
    var pad: InlineArray[UInt8, Self.PAD_BYTES]

    # constructor
    def __init__(out self, initial: UInt64):
        self.atomicVal = Atomic[DType.uint64](initial)
        self.pad = InlineArray[UInt8, Self.PAD_BYTES](uninitialized=True)

# Cell struct used in the MPMC queue, containing a sequence number and the actual data (one slot of the queue)
struct Cell[T: Copyable & Defaultable](Movable):
    var sequence: Atomic[DType.uint64]
    var data: Optional[Self.T]

    # constructor
    def __init__(out self, seq: UInt64):
        self.sequence = Atomic[DType.uint64](seq)
        self.data = Optional[Self.T](None)

    # move constructor
    def __init__(out self, *, deinit take: Self):
        var val = take.sequence.load()
        self.sequence = Atomic[DType.uint64](val)
        self.data = take.data^

# MPMC queue implementation based the algorithm by Dmitry Vyukov
#   (https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue)
struct MPMCQueue[T: Copyable & Defaultable](Movable):
    comptime CellPointer = UnsafePointer[Cell[Self.T], MutExternalOrigin]
    comptime BACKOFF_MIN = 128
    comptime BACKOFF_MAX = 1024
    var buffer: Self.CellPointer
    var size: UInt64
    var mask: UInt64
    var enqueue_pos: PaddedAtomicU64
    var dequeue_pos: PaddedAtomicU64

    # constructor
    def __init__(out self, size: Int):
        if not ((size >= 2) and (size & (size - 1)) == 0):
            print_red_color("{MoStream} Error: MPMC queues need size to be a power of 2 and at least 2!")
            exit(1)
        self.size = UInt64(size)
        self.mask = UInt64(size - 1)
        self.buffer = alloc[Cell[Self.T]](Int(self.size))
        self.enqueue_pos = PaddedAtomicU64(0)
        self.dequeue_pos = PaddedAtomicU64(0)
        for i in range(self.size):
            (self.buffer + i).init_pointee_move(Cell[Self.T](UInt64(i)))

    # move constructor
    def __init__(out self, *, deinit take: Self):
        self.buffer = take.buffer
        self.size = take.size
        self.mask = take.mask
        self.enqueue_pos = PaddedAtomicU64(0)
        self.dequeue_pos = PaddedAtomicU64(0)

    # destructor
    def __del__(deinit self):
        for i in range(self.size):
            (self.buffer + i).destroy_pointee()
        self.buffer.free()

    # push method for producers, always return True because it spins forever until the item is pushed successfully
    def push(mut self, var item: Self.T) -> Bool:
        var pw: UInt64
        var seq: UInt64
        var bk: UInt64 = Self.BACKOFF_MIN
        while True:
            pw = self.enqueue_pos.atomicVal.load[ordering=Ordering.RELAXED]()
            var cell_ptr = self.buffer + (pw & self.mask)
            seq = cell_ptr[].sequence.load[ordering=Ordering.ACQUIRE]()
            if pw == seq:
                if self.enqueue_pos.atomicVal.compare_exchange[failure_ordering=Ordering.RELAXED, success_ordering=Ordering.RELAXED](pw, pw + 1):
                    cell_ptr[].data = Optional(item^)
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=cell_ptr[].sequence.value), pw + 1)
                    return True
                for _ in range(bk):
                    #fence[ordering=Ordering.SEQUENTIAL]() # I am not sure of this, I suppose however that this for loop is compiled out
                    pass
                bk <<= 1
                bk &= Self.BACKOFF_MAX
            # elif pw > seq:
            #    return False

    # pop method for consumers, returns an Optional containing the item if popped successfully,
    #   or None if the queue is empty
    def pop(mut self) -> Optional[Self.T]:
        var pr: UInt64
        var seq: UInt64
        var bk: UInt64 = Self.BACKOFF_MIN
        while True:
            pr = self.dequeue_pos.atomicVal.load[ordering=Ordering.RELAXED]()
            var cell_ptr = self.buffer + (pr & self.mask)
            seq = cell_ptr[].sequence.load[ordering=Ordering.ACQUIRE]()
            var expected_seq = pr + 1
            if seq == expected_seq:
                # element is ready to be consumed, try to claim it by incrementing pr
                if self.dequeue_pos.atomicVal.compare_exchange[failure_ordering=Ordering.RELAXED, success_ordering=Ordering.RELAXED](pr, pr + 1):
                    var item = cell_ptr[].data.take()
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=cell_ptr[].sequence.value), pr + self.mask + 1)
                    return Optional(item^)
                # CAS failed, another consumer might have claimed this item, retry
                for _ in range(bk):
                    #fence[ordering=Ordering.SEQUENTIAL]() # I am not sure of this, I suppose however that this for loop is compiled out
                    pass
                bk <<= 1
                bk &= Self.BACKOFF_MAX
            elif seq < expected_seq:
                # empty slot, the producer has not yet written the item, return None
                return Optional[Self.T](None)
