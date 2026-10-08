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
from std.atomic import Atomic, Ordering
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

# Ready-queue implementations available to the cooperative scheduler
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

# Interface for a logical per-stage ready queue physically sharded by worker
trait ShardedStageReadyQueueBackend(Movable & Deinitable):
    # owner-only push onto a worker's shard for the given stage
    def push_local(mut self, worker_id: Int, stage_idx: Int, actor_id: Int64) -> Bool:
        ...

    # owner-only pop from a worker's shard for the given stage
    def pop_local(mut self, worker_id: Int, stage_idx: Int) -> ReadyQueueResult:
        ...

    # steal from another worker's shard for the selected stage
    def steal_from(mut self, victim_id: Int, stage_idx: Int) -> ReadyQueueResult:
        ...

    # approximate shard size used only as a scheduling hint
    def local_size(mut self, worker_id: Int, stage_idx: Int) -> Int:
        ...

# Round up to a power of two. The extra slot is required by WorkStealingDeque
def ready_queue_capacity(total_actors: Int) -> Int:
    var capacity = 2
    while capacity < total_actors + 1:
        capacity <<= 1
    return capacity

# Chase-Lev ready deques arranged as queues[worker][stage]. The union of all
# worker shards for a stage forms that stage's logical ready queue.
struct SharededStageWorkStealingReadyQueues(ShardedStageReadyQueueBackend):
    var queues: Pointer[WorkStealingDeque, MutUntrackedOrigin]
    var num_workers: Int
    var num_stages: Int

    # constructor
    def __init__(out self, num_workers: Int, num_stages: Int, capacity: Int) raises:
        self.num_workers = num_workers
        self.num_stages = num_stages
        var queue_count = num_workers * num_stages
        self.queues = unsafe_alloc[WorkStealingDeque](queue_count)
        for queue_idx in range(queue_count):
            self.queues.unsafe_offset(queue_idx).unsafe_write(WorkStealingDeque(capacity))

    # move constructor
    def __init__(out self, *, deinit move: Self):
        self.queues = move.queues
        self.num_workers = move.num_workers
        self.num_stages = move.num_stages

    # destructor
    def __deinit__(deinit self):
        for queue_idx in range(self.num_workers * self.num_stages):
            self.queues.unsafe_offset(queue_idx).unsafe_deinit_pointee()
        self.queues.unsafe_free()

    # convert worker and stage coordinates to the flattened queue index
    @always_inline
    def _queue_idx(self, worker_id: Int, stage_idx: Int) -> Int:
        return worker_id * self.num_stages + stage_idx

    # push onto the bottom of the owner's stage shard
    def push_local(mut self, worker_id: Int, stage_idx: Int, actor_id: Int64) -> Bool:
        var queue_idx = self._queue_idx(worker_id, stage_idx)
        return self.queues.unsafe_offset(queue_idx)[].push_bottom(actor_id)

    # pop from the bottom of the owner's stage shard
    def pop_local(mut self, worker_id: Int, stage_idx: Int) -> ReadyQueueResult:
        var queue_idx = self._queue_idx(worker_id, stage_idx)
        return self._convert_result(self.queues.unsafe_offset(queue_idx)[].pop_bottom())

    # steal from the top of a victim's shard for the selected stage
    def steal_from(mut self, victim_id: Int, stage_idx: Int) -> ReadyQueueResult:
        var queue_idx = self._queue_idx(victim_id, stage_idx)
        return self._convert_result(self.queues.unsafe_offset(queue_idx)[].steal_top())

    # approximate size of one physical shard
    def local_size(mut self, worker_id: Int, stage_idx: Int) -> Int:
        var queue_idx = self._queue_idx(worker_id, stage_idx)
        return self.queues.unsafe_offset(queue_idx)[].size()

    # convert a WorkStealResult to the scheduler's common result
    @staticmethod
    def _convert_result(result: WorkStealResult) -> ReadyQueueResult:
        if result.status == WorkStealResult.SUCCESS:
            return ReadyQueueResult.success(result.actor_id)
        if result.status == WorkStealResult.RETRY:
            return ReadyQueueResult.retry()
        return ReadyQueueResult.empty()
