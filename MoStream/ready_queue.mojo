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

from MoStream.MPMC_queue import MPMCQueue
from MoStream.work_stealing_deque import WorkStealingDeque, WorkStealResult
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

# Ready-queue implementations available to the cooperative scheduler.
struct ReadyQueueKind:
    comptime MPMC: Int = 0
    comptime WORK_STEALING: Int = 1

# Common result returned by local pops and remote steals
struct ReadyQueueResult(ImplicitlyCopyable):
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
    def success(actor_id: Int64) -> ReadyQueueResult:
        return ReadyQueueResult(ReadyQueueResult.SUCCESS, actor_id)

    # create an EMPTY result
    @staticmethod
    def empty() -> ReadyQueueResult:
        return ReadyQueueResult(ReadyQueueResult.EMPTY)

    # create a RETRY result
    @staticmethod
    def retry() -> ReadyQueueResult:
        return ReadyQueueResult(ReadyQueueResult.RETRY)

# Interface used by Scheduler. Only the owning worker may push or pop locally;
# other workers access a queue through steal_from.
trait ReadyQueueBackend(Movable & Deinitable):
    # push an actor ID onto the local queue. Returns true if successful, false if the queue is full
    def push_local(mut self, worker_id: Int, actor_id: Int64) -> Bool:
        ...

    # pop an actor ID from the local queue. Returns a ReadyQueueResult indicating success, empty, or retry
    def pop_local(mut self, worker_id: Int) -> ReadyQueueResult:
        ...

    # steal an actor ID from the given victim queue. Returns a ReadyQueueResult indicating success, empty, or retry
    def steal_from(mut self, victim_id: Int) -> ReadyQueueResult:
        ...

# Round up to a power of two. The extra slot is required by WorkStealingDeque
def ready_queue_capacity(total_actors: Int) -> Int:
    var capacity = 2
    while capacity < total_actors + 1:
        capacity <<= 1
    return capacity

# Per-worker bounded MPMC queues behind the scheduler's common queue API
struct MPMCReadyQueues(ReadyQueueBackend):
    var queues: Pointer[MPMCQueue[Int64], MutUntrackedOrigin]
    var num_workers: Int

    # constructor
    def __init__(out self, num_workers: Int, capacity: Int) raises:
        self.num_workers = num_workers
        self.queues = unsafe_alloc[MPMCQueue[Int64]](num_workers)
        for worker_id in range(num_workers):
            self.queues.unsafe_offset(worker_id).unsafe_write(MPMCQueue[Int64](capacity))

    # move constructor
    def __init__(out self, *, deinit move: Self):
        self.queues = move.queues
        self.num_workers = move.num_workers

    # destructor
    def __deinit__(deinit self):
        for worker_id in range(self.num_workers):
            self.queues.unsafe_offset(worker_id).unsafe_deinit_pointee()
        self.queues.unsafe_free()

    # push an actor ID onto the local queue. Returns true if successful, false if the queue is full
    def push_local(mut self, worker_id: Int, actor_id: Int64) -> Bool:
        var rejected = self.queues.unsafe_offset(worker_id)[].try_push(actor_id)
        return not rejected

    # pop an actor ID from the local queue. Returns a ReadyQueueResult indicating success or empty
    def pop_local(mut self, worker_id: Int) -> ReadyQueueResult:
        var actor_id = self.queues.unsafe_offset(worker_id)[].try_pop()
        if actor_id:
            return ReadyQueueResult.success(actor_id.take())
        return ReadyQueueResult.empty()

    # steal an actor ID from the given victim queue. Returns a ReadyQueueResult indicating success or empty
    def steal_from(mut self, victim_id: Int) -> ReadyQueueResult:
        var actor_id = self.queues.unsafe_offset(victim_id)[].try_pop()
        if actor_id:
            return ReadyQueueResult.success(actor_id.take())
        return ReadyQueueResult.empty()

# Per-worker Chase-Lev deques behind the scheduler's common queue API
struct WorkStealingReadyQueues(ReadyQueueBackend):
    var queues: Pointer[WorkStealingDeque, MutUntrackedOrigin]
    var num_workers: Int

    # constructor
    def __init__(out self, num_workers: Int, capacity: Int) raises:
        self.num_workers = num_workers
        self.queues = unsafe_alloc[WorkStealingDeque](num_workers)
        for worker_id in range(num_workers):
            self.queues.unsafe_offset(worker_id).unsafe_write(WorkStealingDeque(capacity))

    # move constructor
    def __init__(out self, *, deinit move: Self):
        self.queues = move.queues
        self.num_workers = move.num_workers

    # destructor
    def __deinit__(deinit self):
        for worker_id in range(self.num_workers):
            self.queues.unsafe_offset(worker_id).unsafe_deinit_pointee()
        self.queues.unsafe_free()

    # push an actor ID onto the local queue. Returns true if successful, false if the queue is full
    def push_local(mut self, worker_id: Int, actor_id: Int64) -> Bool:
        return self.queues.unsafe_offset(worker_id)[].push_bottom(actor_id)

    # pop an actor ID from the local queue. Returns a ReadyQueueResult indicating success or empty
    def pop_local(mut self, worker_id: Int) -> ReadyQueueResult:
        return self._convert_result(self.queues.unsafe_offset(worker_id)[].pop_bottom())

    # steal an actor ID from the given victim queue. Returns a ReadyQueueResult indicating success, empty, or retry
    def steal_from(mut self, victim_id: Int) -> ReadyQueueResult:
        return self._convert_result(self.queues.unsafe_offset(victim_id)[].steal_top())

    # convert a WorkStealResult to a ReadyQueueResult
    @staticmethod
    def _convert_result(result: WorkStealResult) -> ReadyQueueResult:
        if result.status == WorkStealResult.SUCCESS:
            return ReadyQueueResult.success(result.actor_id)
        if result.status == WorkStealResult.RETRY:
            return ReadyQueueResult.retry()
        return ReadyQueueResult.empty()
