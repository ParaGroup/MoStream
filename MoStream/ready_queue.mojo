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

# Interface used by the pressure-aware scheduler. Every queue is shared by all
# workers and contains the ready actors belonging to one pipeline stage
trait StageReadyQueueBackend(Movable & Deinitable):
    # push an actor ID onto its stage queue
    def push_stage(mut self, stage_idx: Int, actor_id: Int64) -> Bool:
        ...

    # pop an actor ID from a stage queue
    def pop_stage(mut self, stage_idx: Int) -> ReadyQueueResult:
        ...

    # approximate count used only to identify stages that may be eligible
    def ready_count(mut self, stage_idx: Int) -> Int64:
        ...

# Round up to a power of two. The extra slot is required by WorkStealingDeque
def ready_queue_capacity(total_actors: Int) -> Int:
    var capacity = 2
    while capacity < total_actors + 1:
        capacity <<= 1
    return capacity

# Shared bounded MPMC ready queue for every pipeline stage
struct StageMPMCReadyQueues(StageReadyQueueBackend):
    var queues: Pointer[MPMCQueue[Int64], MutUntrackedOrigin]
    var ready_counts: Pointer[Atomic[DType.int64], MutUntrackedOrigin]
    var num_stages: Int

    # constructor
    def __init__(out self, num_stages: Int, capacity: Int) raises:
        self.num_stages = num_stages
        self.queues = unsafe_alloc[MPMCQueue[Int64]](num_stages)
        self.ready_counts = unsafe_alloc[Atomic[DType.int64]](num_stages)
        for stage_idx in range(num_stages):
            self.queues.unsafe_offset(stage_idx).unsafe_write(MPMCQueue[Int64](capacity))
            self.ready_counts.unsafe_offset(stage_idx)[] = Atomic[DType.int64](0)

    # move constructor
    def __init__(out self, *, deinit move: Self):
        self.queues = move.queues
        self.ready_counts = move.ready_counts
        self.num_stages = move.num_stages

    # destructor
    def __deinit__(deinit self):
        for stage_idx in range(self.num_stages):
            self.queues.unsafe_offset(stage_idx).unsafe_deinit_pointee()
            self.ready_counts.unsafe_offset(stage_idx).unsafe_deinit_pointee()
        self.queues.unsafe_free()
        self.ready_counts.unsafe_free()

    # push an actor ID and publish the stage as eligible
    def push_stage(mut self, stage_idx: Int, actor_id: Int64) -> Bool:
        self.queues.unsafe_offset(stage_idx)[].push(actor_id)
        _ = self.ready_counts.unsafe_offset(stage_idx)[].fetch_add[
            ordering=Ordering.RELEASE
        ](1)
        return True

    # pop an actor ID and update the approximate eligibility count
    def pop_stage(mut self, stage_idx: Int) -> ReadyQueueResult:
        var actor_id = self.queues.unsafe_offset(stage_idx)[].try_pop()
        if actor_id:
            _ = self.ready_counts.unsafe_offset(stage_idx)[].fetch_sub[
                ordering=Ordering.ACQUIRE_RELEASE
            ](1)
            return ReadyQueueResult.success(actor_id.take())
        return ReadyQueueResult.empty()

    # return the approximate number of ready actors in a stage queue
    def ready_count(mut self, stage_idx: Int) -> Int64:
        return self.ready_counts.unsafe_offset(stage_idx)[].load[
            ordering=Ordering.ACQUIRE
        ]()
