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

from std.atomic import Atomic, Ordering
from std.collections import Optional
from MoStream.MPMC_queue import MPMCQueue
from MoStream.ready_queue import ShardedStageReadyQueueBackend, ReadyQueueResult
from MoStream.actor import ActorStatus
from MoStream.pipeline import CoresList, pin_thread_to_cpu
from MoStream.node import NodeTrait, SeqNode, ParallelNode
from MoStream.utils import print_cyan_color, print_red_color, print_yellow_color
from std.runtime.asyncrt import create_task, TaskGroup, parallelism_level
from std.sys.terminate import exit
from std.memory.alloc import unsafe_alloc
from std.memory import Pointer

# ActorDescriptor
struct ActorDescriptor(ImplicitlyCopyable):
    var stage_idx: Int # identifier of the pipeline stage
    var replica_idx: Int # identifier of the node local to the stage
    var flat_id: Int # identifier of the node in the whole pipeline

    # constructor
    def __init__(out self, stage_idx: Int, replica_idx: Int, flat_id: Int):
        self.stage_idx = stage_idx
        self.replica_idx = replica_idx
        self.flat_id = flat_id

# Scheduler
struct Scheduler[ReadyQueues: ShardedStageReadyQueueBackend, *Ts: NodeTrait]:
    var num_stages: Int # number of stages in the pipeline
    var total_actors: Int # total number of actors in the pipeline (sum of parallelism degrees of all stages)
    var num_workers: Int # number of workers used by the cooperative scheduler
    var ready_queues: Self.ReadyQueues # one physical ready deque for each worker and stage
    var actor_descriptors: Pointer[ActorDescriptor, MutUntrackedOrigin] # array of actor descriptors indexed by flat actor ID
    var wq_inputs: Pointer[MPMCQueue[ActorDescriptor], MutUntrackedOrigin] # array of wait queues for actors waiting on input
    var wq_outputs: Pointer[MPMCQueue[ActorDescriptor], MutUntrackedOrigin] # array of wait queues for actors waiting on output
    var actor_states: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic variables representing the state of each actor
    var done_count: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # counter of actors that have finished execution
    var actor_busy: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic flags to protect parking logic

    # constructor
    def __init__(out self, mut nodes: Tuple[*Self.Ts], num_workers: Int, var ready_queues: Self.ReadyQueues) raises:
        self.num_stages = len(Self.Ts)
        self.total_actors = 0
        self.num_workers = num_workers
        self.ready_queues = ready_queues^
        comptime for i in range(len(Self.Ts)):
            self.total_actors += nodes[i].parallelism()
        self.actor_descriptors = unsafe_alloc[ActorDescriptor](self.total_actors)
        var flat_id = 0
        comptime for stage_idx in range(len(Self.Ts)):
            for replica_idx in range(nodes[stage_idx].parallelism()):
                self.actor_descriptors.unsafe_offset(flat_id).unsafe_write(ActorDescriptor(stage_idx, replica_idx, flat_id))
                flat_id += 1
        self.wq_inputs = unsafe_alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
        self.wq_outputs = unsafe_alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
        for i in range(self.num_stages):
            self.wq_inputs.unsafe_offset(i).unsafe_write(MPMCQueue[ActorDescriptor](1048576)) # how to compute this size?
            self.wq_outputs.unsafe_offset(i).unsafe_write(MPMCQueue[ActorDescriptor](1048576)) # how to compute this size?
        self.actor_states = unsafe_alloc[Atomic[DType.uint64]](self.total_actors)
        for i in range(self.total_actors):
            self.actor_states.unsafe_offset(i)[] = Atomic[DType.uint64](ActorStatus.READY)
        self.done_count = unsafe_alloc[Atomic[DType.uint64]](1)
        self.done_count[] = Atomic[DType.uint64](0)
        self.actor_busy = unsafe_alloc[Atomic[DType.uint64]](self.total_actors)
        for i in range(self.total_actors):
            self.actor_busy.unsafe_offset(i)[] = Atomic[DType.uint64](0)

    # destructor
    def __deinit__(deinit self):
        for i in range(self.total_actors):
            self.actor_descriptors.unsafe_offset(i).unsafe_deinit_pointee()
        self.actor_descriptors.unsafe_free()
        for i in range(self.num_stages):
            self.wq_inputs.unsafe_offset(i).unsafe_deinit_pointee()
            self.wq_outputs.unsafe_offset(i).unsafe_deinit_pointee()
        self.wq_inputs.unsafe_free()
        self.wq_outputs.unsafe_free()
        for i in range(self.total_actors):
            self.actor_states.unsafe_offset(i).unsafe_deinit_pointee()
        self.actor_states.unsafe_free()
        self.done_count.unsafe_deinit_pointee()
        self.done_count.unsafe_free()
        for i in range(self.total_actors):
            self.actor_busy.unsafe_offset(i).unsafe_deinit_pointee()
        self.actor_busy.unsafe_free()

    # make an actor ready to run
    def schedule_actor(mut self, actor: ActorDescriptor, worker_id: Int):
        if not self.ready_queues.push_local(worker_id, actor.stage_idx, Int64(actor.flat_id)):
            print_red_color("{MoStream} Error: cooperative ready queue is full!")
            exit(1)

    # make all actors ready to run (only used at the beginning of the execution)
    def enqueue_all_actors(mut self):
        for flat_id in range(self.total_actors):
            self.schedule_actor(self.actor_descriptors.unsafe_offset(flat_id)[], flat_id % self.num_workers)

    # start the scheduler in cooperative mode
    def start(mut self, mut nodes: Tuple[*Self.Ts], mut coreslist: CoresList) raises:
        self.enqueue_all_actors()
        var tg = TaskGroup()
        for worker_id in range(0, self.num_workers):
            var core_id = coreslist.get_next_core_id()
            var task = self.worker_loop(nodes, worker_id, core_id)
            tg.create_task(task^)
        tg.wait()
        self.destroy_communicators(nodes)

    # Cooperative actors share communicator pointers. Release every edge only
    # after workers can no longer read its occupancy while selecting a stage.
    def destroy_communicators(mut self, mut nodes: Tuple[*Self.Ts]) raises:
        comptime for stage_idx in range(1, len(Self.Ts)):
            var communicator = nodes[stage_idx].actor_ref(0)[].in_comm
            communicator.unsafe_deinit_pointee()
            communicator.unsafe_free()

    # get the input wait queue index for an actor
    @always_inline
    def input_wait_queue_idx(self, actor: ActorDescriptor) -> Int:
        return actor.stage_idx - 1

    # get the output wait queue index for an actor
    @always_inline
    def output_wait_queue_idx(self, actor: ActorDescriptor) -> Int:
        return actor.stage_idx

    # try to start an actor, return true if successful, false otherwise
    def try_start_actor(mut self, actor: ActorDescriptor) -> Bool:
        var expected = ActorStatus.READY
        return self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.RUNNING)

    # mark a running actor as ready to run
    def mark_from_running_to_ready(mut self, actor: ActorDescriptor, worker_id: Int):
        var expected = ActorStatus.RUNNING
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.READY):
            self.schedule_actor(actor, worker_id)

    # mark a running actor as done
    def mark_from_running_to_done(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.DONE):
            _ = self.done_count[].fetch_add[ordering=Ordering.ACQUIRE_RELEASE](1)

    # mark a blocked actor (BLOCKED_INPUT or BLOCKED_OUTPUT) as ready to run
    def mark_from_blocked_to_ready(mut self, actor: ActorDescriptor, blocked_state: UInt64, worker_id: Int):
        var expected = blocked_state
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.READY):
            self.schedule_actor(actor, worker_id)

    # set an actor as busy (to protect parking logic)
    def set_busy(mut self, actor: ActorDescriptor) raises:
        var expected = UInt64(0) # non-busy
        if not self.actor_busy.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.ACQUIRE_RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, UInt64(1)): # busy
            print_yellow_color("MoStream Warning: actor " + String(actor.flat_id) + " is already busy in set_busy()")
            raise Error("error in set_busy()")

    # set an actor as non-busy (to protect parking logic)
    def set_not_busy(mut self, actor: ActorDescriptor) raises:
        var expected = UInt64(1) # busy
        if not self.actor_busy.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, UInt64(0)): # non-busy
            print_yellow_color("MoStream Warning: actor " + String(actor.flat_id) + " is already not busy in set_not_busy()")
            raise Error("error in set_not_busy()")

    # spin until the actor is busy
    def spin_until_not_busy(mut self, actor: ActorDescriptor):
        while self.actor_busy.unsafe_offset(actor.flat_id)[].load[ordering=Ordering.ACQUIRE]() == UInt64(1):
            continue

    # process an actor: static dispatching
    def process_actor(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises -> UInt64:
        comptime for i in range(len(Self.Ts)):
            if actor.stage_idx == i:
                return nodes[i].actor_ref(actor.replica_idx)[].process()
        return ActorStatus.ERROR

    # try to reserve an input for parking, returns true if successful
    def try_reserve_input_for_actor(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises -> Bool:
        comptime for i in range(len(Self.Ts)):
            if actor.stage_idx == i:
                return nodes[i].actor_ref(actor.replica_idx)[].try_pop_input_for_parking()
        return False

    # try to push the pending output for parking, returns true if successful
    def retry_push_pending_output_for_actor(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises -> Bool:
        comptime for i in range(len(Self.Ts)):
            if actor.stage_idx == i:
                return nodes[i].actor_ref(actor.replica_idx)[].retry_push_pending_output()
        return False

    # check if the input communicator of an actor is closed
    def actor_input_is_closed(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises -> Bool:
        comptime for i in range(len(Self.Ts)):
            if actor.stage_idx == i:
                return nodes[i].actor_ref(actor.replica_idx)[].in_comm[].is_closed()
        return True

    # check if the output communicator of an actor is closed
    def actor_output_is_closed(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises -> Bool:
        comptime for i in range(len(Self.Ts)):
            if actor.stage_idx == i:
                return nodes[i].actor_ref(actor.replica_idx)[].out_comm[].is_closed()
        return True

    # try to wake an actor waiting on its input queue
    def wake_one_input_waiter(mut self, comm_idx: Int, worker_id: Int):
        while True:
            var maybe_actor = self.wq_inputs.unsafe_offset(comm_idx)[].try_pop()
            if not maybe_actor:
                return
            var actor = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_INPUT
            if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.schedule_actor(actor, worker_id)
                return

    # try to wake all actors waiting on the same input queue
    def wake_all_input_waiters(mut self, comm_idx: Int, worker_id: Int):
        while True:
            var maybe_actor = self.wq_inputs.unsafe_offset(comm_idx)[].try_pop()
            if not maybe_actor:
                return
            var actor = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_INPUT
            if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.schedule_actor(actor, worker_id)

    # try to wake an actor waiting on its output queue
    def wake_one_output_waiter(mut self, comm_idx: Int, worker_id: Int):
        while True:
            var maybe_actor = self.wq_outputs.unsafe_offset(comm_idx)[].try_pop()
            if not maybe_actor:
                return
            var actor = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_OUTPUT
            if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.schedule_actor(actor, worker_id)
                return

    # force waking some actors on the input queue to make room for new waiters
    def try_make_room_input(mut self, comm_idx: Int, max_pops: Int, worker_id: Int):
        for _ in range(max_pops):
            var maybe_actor = self.wq_inputs.unsafe_offset(comm_idx)[].try_pop()
            if not maybe_actor:
                return
            var stale = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_INPUT
            if self.actor_states.unsafe_offset(stale.flat_id)[].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.schedule_actor(stale, worker_id)
                return

    # force waking some actors on the output queue to make room for new waiters
    def try_make_room_output(mut self, comm_idx: Int, max_pops: Int, worker_id: Int):
        for _ in range(max_pops):
            var maybe_actor = self.wq_outputs.unsafe_offset(comm_idx)[].try_pop()
            if not maybe_actor:
                return
            var stale = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_OUTPUT
            if self.actor_states.unsafe_offset(stale.flat_id)[].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.schedule_actor(stale, worker_id)
                return

    # put the actor in the BLOCKING_INPUT state or mark it ready if already available
    def park_on_input_or_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor, worker_id: Int) raises:
        if actor.stage_idx == 0:
            self.mark_from_running_to_ready(actor, worker_id)
            return
        var comm_idx = self.input_wait_queue_idx(actor)
        self.set_busy(actor) # protect
        var expected = ActorStatus.RUNNING
        if not self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.BLOCKED_INPUT):
            self.set_not_busy(actor) # unprotect
            return
        var not_queued = self.wq_inputs.unsafe_offset(comm_idx)[].try_push(actor)
        if not_queued:
            self.try_make_room_input(comm_idx, 8, worker_id)
            not_queued = self.wq_inputs.unsafe_offset(comm_idx)[].try_push(actor)
        if not_queued:
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_INPUT, worker_id)
            self.set_not_busy(actor) # unprotect
            return
        if self.try_reserve_input_for_actor(nodes, actor):
            self.wake_one_output_waiter(comm_idx, worker_id)
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_INPUT, worker_id)
            self.set_not_busy(actor) # unprotect
            return
        if self.actor_input_is_closed(nodes, actor):
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_INPUT, worker_id)
        self.set_not_busy(actor) # unprotect

    # put the actor in the BLOCKING_OUTPUT state or mark it ready if already available
    def park_on_output_or_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor, worker_id: Int) raises:
        var comm_idx = self.output_wait_queue_idx(actor)
        self.set_busy(actor) # protect
        var expected = ActorStatus.RUNNING
        if not self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.BLOCKED_OUTPUT):
            self.set_not_busy(actor) # unprotect
            return
        var not_queued = self.wq_outputs.unsafe_offset(comm_idx)[].try_push(actor)
        if not_queued:
            self.try_make_room_output(comm_idx, 8, worker_id)
            not_queued = self.wq_outputs.unsafe_offset(comm_idx)[].try_push(actor)
        if not_queued:
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_OUTPUT, worker_id)
            self.set_not_busy(actor) # unprotect
            return
        if self.retry_push_pending_output_for_actor(nodes, actor):
            self.wake_one_input_waiter(comm_idx, worker_id)
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_OUTPUT, worker_id)
        self.set_not_busy(actor) # unprotect

    # notification method after processing an actor returning READY
    def notify_after_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor, worker_id: Int) raises:
        # the actor might have consumed an input, capacity may have been freed upstream
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor), worker_id)
        # the actor might have produced output(s), data may be available downstream
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_one_input_waiter(self.output_wait_queue_idx(actor), worker_id)

    # notification method after processing an actor returning BLOCKED_INPUT
    def notify_after_blocked_input(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor, worker_id: Int) raises:
        # the actor might have produced output(s), data may be available downstream
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_one_input_waiter(self.output_wait_queue_idx(actor), worker_id)

    # notification method after processing an actor returning BLOCKED_OUTPUT
    def notify_after_blocked_output(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor, worker_id: Int) raises:
        # the actor might have consumed an input, capacity may have been freed upstream
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor), worker_id)

    # notification method after processing an actor returning DONE
    def notify_after_done(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor, worker_id: Int) raises:
        # a DONE transform/sink may have consumed input or observed EOS. Waking an
        # upstream producer is harmless and can release capacity waiters
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor), worker_id)
        # a DONE source/transform may have closed its output communicator. If it is
        # closed, all downstream input waiters must be woken so they can observe EOS
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            if self.actor_output_is_closed(nodes, actor):
                self.wake_all_input_waiters(self.output_wait_queue_idx(actor), worker_id)
            else:
                self.wake_one_input_waiter(self.output_wait_queue_idx(actor), worker_id)

    # Compute input_fill * output_free for a stage. Sources have an implicit
    # full input and sinks have an implicit empty output
    @always_inline
    def stage_priority[stage_idx: Int](mut self, mut nodes: Tuple[*Self.Ts]) raises -> Float64:
        var input_fill = 1.0
        var output_free = 1.0
        comptime if stage_idx > 0:
            input_fill = nodes[stage_idx].actor_ref(0)[].in_comm[].fill_ratio()
        comptime if stage_idx < len(Self.Ts) - 1:
            output_free = 1.0 - nodes[stage_idx].actor_ref(0)[].out_comm[].fill_ratio()
        return input_fill * output_free

    # Select the highest-priority stage that has work in this worker's shard
    def select_local_stage(mut self, mut nodes: Tuple[*Self.Ts], worker_id: Int, first_stage: Int) raises -> Int:
        var selected_stage = -1
        var best_priority = -1.0
        var best_rank = self.num_stages
        comptime for stage_idx in range(len(Self.Ts)):
            if self.ready_queues.local_size(worker_id, stage_idx) > 0:
                var priority = self.stage_priority[stage_idx](nodes)
                var rank = (stage_idx - first_stage + self.num_stages) % self.num_stages
                if (selected_stage < 0 or priority > best_priority or (priority == best_priority and rank < best_rank)):
                    selected_stage = stage_idx
                    best_priority = priority
                    best_rank = rank
        return selected_stage

    # Select the highest-priority stage that appears to have work on another worker. Queue-size observations are hints and may be stale
    def select_remote_stage(mut self, mut nodes: Tuple[*Self.Ts], worker_id: Int, first_stage: Int, first_victim: Int) raises -> Int:
        var selected_stage = -1
        var best_priority = -1.0
        var best_rank = self.num_stages
        comptime for stage_idx in range(len(Self.Ts)):
            var has_remote_work = False
            for offset in range(self.num_workers):
                var victim_id = (first_victim + offset) % self.num_workers
                if victim_id == worker_id:
                    continue
                if self.ready_queues.local_size(victim_id, stage_idx) > 0:
                    has_remote_work = True
                    break
            if has_remote_work:
                var priority = self.stage_priority[stage_idx](nodes)
                var rank = (stage_idx - first_stage + self.num_stages) % self.num_stages
                if (selected_stage < 0 or priority > best_priority or (priority == best_priority and rank < best_rank)):
                    selected_stage = stage_idx
                    best_priority = priority
                    best_rank = rank
        return selected_stage

    # Consume the highest-priority locally available actor.
    def try_pop_local_actor(mut self, mut nodes: Tuple[*Self.Ts], worker_id: Int, first_stage: Int) raises -> Optional[ActorDescriptor]:
        while True:
            var selected_stage = self.select_local_stage(nodes, worker_id, first_stage)
            if selected_stage < 0:
                return None
            var result = self.ready_queues.pop_local(worker_id, selected_stage)
            if result.status == ReadyQueueResult.SUCCESS:
                return Optional(self.actor_descriptors.unsafe_offset(Int(result.actor_id))[])

    # Steal from the highest-priority stage that has work on another worker.
    def try_steal_actor(mut self, mut nodes: Tuple[*Self.Ts], worker_id: Int, first_stage: Int, first_victim: Int) raises -> Optional[ActorDescriptor]:
        while True:
            var selected_stage = self.select_remote_stage(nodes, worker_id, first_stage, first_victim)
            if selected_stage < 0:
                return None
            for offset in range(self.num_workers):
                var victim_id = (first_victim + offset) % self.num_workers
                if victim_id == worker_id:
                    continue
                var result = self.ready_queues.steal_from(victim_id, selected_stage)
                if result.status == ReadyQueueResult.SUCCESS:
                    return Optional(self.actor_descriptors.unsafe_offset(Int(result.actor_id))[])

    # Prefer pressure-ranked local work, then steal from a pressure-ranked remote stage only when the worker has no local actor
    def try_get_actor(mut self, mut nodes: Tuple[*Self.Ts], worker_id: Int, first_stage: Int, first_victim: Int) raises -> Optional[ActorDescriptor]:
        var local_actor = self.try_pop_local_actor(nodes, worker_id, first_stage)
        if local_actor:
            return Optional(local_actor.take())
        return self.try_steal_actor(nodes, worker_id, first_stage, first_victim)

    # main worker loop
    async def worker_loop(mut self, mut nodes: Tuple[*Self.Ts], worker_id: Int, core_id: Int):
        try:
            # pinning of the underlying thread if pinning is enabled
            _ = pin_thread_to_cpu(core_id)
            var first_stage = worker_id % self.num_stages
            var first_victim = (worker_id + 1) % self.num_workers
            while self.done_count[].load[ordering=Ordering.ACQUIRE]() < UInt64(self.total_actors):
                var maybe_actor = self.try_get_actor(nodes, worker_id, first_stage, first_victim)
                first_stage = (first_stage + 1) % self.num_stages
                first_victim = (first_victim + 1) % self.num_workers
                if not maybe_actor:
                    continue
                var actor = maybe_actor.take()
                if not self.try_start_actor(actor):
                    continue
                self.spin_until_not_busy(actor) # to avoid inter-mixing with the parking logic
                var max_rounds = 1 # rounds represent a sort of quantum assigned to a ready actor
                for i in range(max_rounds):
                    var result = self.process_actor(nodes, actor)
                    if result == ActorStatus.READY:
                        self.notify_after_ready(nodes, actor, worker_id)
                        if (i == max_rounds - 1):
                            self.mark_from_running_to_ready(actor, worker_id)
                    elif result == ActorStatus.BLOCKED_INPUT:
                        self.notify_after_blocked_input(nodes, actor, worker_id)
                        self.park_on_input_or_ready(nodes, actor, worker_id)
                        break
                    elif result == ActorStatus.BLOCKED_OUTPUT:
                        self.notify_after_blocked_output(nodes, actor, worker_id)
                        self.park_on_output_or_ready(nodes, actor, worker_id)
                        break
                    elif result == ActorStatus.DONE:
                        self.notify_after_done(nodes, actor, worker_id)
                        self.mark_from_running_to_done(actor)
                        break
                    else:
                        self.mark_from_running_to_done(actor)
                        break
        except e:
            print("Raised: " + String(e))
            exit(1)
