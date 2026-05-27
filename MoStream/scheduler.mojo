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
from MoStream.MPMC_queue import MPMCQueue
from MoStream.actor import ActorStatus
from MoStream.pipeline import Pinning
from MoStream.node import NodeTrait, SeqNode, ParallelNode
from MoStream.utils import print_cyan_color, print_red_color, print_yellow_color
from std.runtime.asyncrt import create_task, TaskGroup, parallelism_level
from std.sys.terminate import exit

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
struct Scheduler[*Ts: NodeTrait]:
    var num_stages: Int # number of stages in the pipeline
    var total_actors: Int # total number of actors in the pipeline (sum of parallelism degrees of all stages)
    var ready_queue: UnsafePointer[MPMCQueue[ActorDescriptor], MutExternalOrigin] # ready queue for actors that are ready to run
    var wq_inputs: UnsafePointer[MPMCQueue[ActorDescriptor], MutExternalOrigin] # array of wait queues for actors waiting on input 
    var wq_outputs: UnsafePointer[MPMCQueue[ActorDescriptor], MutExternalOrigin] # array of wait queues for actors waiting on output
    var actor_states: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin] # array of atomic variables representing the state of each actor
    var done_count: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin] # count of actors that have finished execution
    var actor_busy: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin] # flag to indicate if an actor is currently being processed (for debugging)

    # constructor
    def __init__(out self, mut nodes: Tuple[*Self.Ts]) raises:
        self.num_stages = len(Self.Ts)
        self.total_actors = 0
        comptime for i in range(len(Self.Ts)):
            self.total_actors += nodes[i].parallelism()
        self.ready_queue = alloc[MPMCQueue[ActorDescriptor]](1)
        self.ready_queue.init_pointee_move(MPMCQueue[ActorDescriptor](1048576))
        var flat_id = 0
        comptime for i in range(len(Self.Ts)): # i is the stage index
             var parDegree = nodes[i].parallelism()
             for j in range(parDegree): # j is the node index within the stage
                self.ready_queue[].push(ActorDescriptor(stage_idx=i, replica_idx=j, flat_id=flat_id))
                flat_id += 1
        self.wq_inputs = alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
        self.wq_outputs = alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
        for i in range(self.num_stages):
            (self.wq_inputs + i).init_pointee_move(MPMCQueue[ActorDescriptor](1048576))
            (self.wq_outputs + i).init_pointee_move(MPMCQueue[ActorDescriptor](1048576))
        self.actor_states = alloc[Atomic[DType.uint64]](self.total_actors)
        for i in range(self.total_actors):
            (self.actor_states+i)[] = Atomic[DType.uint64](ActorStatus.READY)
        self.done_count = alloc[Atomic[DType.uint64]](1)
        self.done_count[] = Atomic[DType.uint64](0)
        self.actor_busy = alloc[Atomic[DType.uint64]](self.total_actors)
        for i in range(self.total_actors):
            (self.actor_busy+i)[] = Atomic[DType.uint64](0)

    # destructor
    def __del__(deinit self):
        self.ready_queue.destroy_pointee()
        self.ready_queue.free()
        for i in range(self.num_stages):
            (self.wq_inputs + i).destroy_pointee()
            (self.wq_outputs + i).destroy_pointee()
        self.wq_inputs.free()
        self.wq_outputs.free()
        for i in range(self.total_actors):
            (self.actor_states + i).destroy_pointee()
        self.actor_states.free()
        self.done_count.destroy_pointee()
        self.done_count.free()
        for i in range(self.total_actors):
            (self.actor_busy + i).destroy_pointee()
        self.actor_busy.free()

    # start the scheduler
    def start(mut self, mut nodes: Tuple[*Self.Ts], n_workers: Int, mut pinning_handler: Pinning):
        var tg = TaskGroup()
        for _ in range(0, n_workers):
            tg.create_task(self.worker_loop(nodes, pinning_handler.get_next_core_id(), pinning_handler))        
        tg.wait()

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
        return self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.RUNNING)

    # mark an actor as finished and ready to run again
    def mark_ready(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.READY):
            self.ready_queue[].push(actor)

    # mark an actor as done
    def mark_done(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.DONE):
            _ = self.done_count[].fetch_add[ordering=Ordering.ACQUIRE_RELEASE](1) # ordering is safer, RELEASE should be still fine

    # set an actor as busy (to protect parking logic)
    def set_busy(mut self, actor: ActorDescriptor) raises:
        var expected = UInt64(0) # non-busy
        if not self.actor_busy[actor.flat_id].compare_exchange[
            success_ordering=Ordering.ACQUIRE_RELEASE, # ordering is safer, RELEASE should be still fine
            failure_ordering=Ordering.RELAXED]
            (expected, UInt64(1)): # busy
            print_yellow_color("MoStream Warning: actor " + String(actor.flat_id) + " is already busy in set_busy()")
            raise Error("error in set_busy()")

    def set_not_busy(mut self, actor: ActorDescriptor) raises:
        var expected = UInt64(1) # busy
        if not self.actor_busy[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, UInt64(0)): # non-busy
            print_yellow_color("MoStream Warning: actor " + String(actor.flat_id) + " is already not busy in set_not_busy()")
            raise Error("error in set_not_busy()")

    # spin until the actor is not busy
    def spin_until_not_busy(mut self, actor: ActorDescriptor):
        while self.actor_busy[actor.flat_id].load[ordering=Ordering.ACQUIRE]() == UInt64(1):
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

    # mark a blocked actor as ready to run
    def mark_blocked_ready(mut self, actor: ActorDescriptor, blocked_state: UInt64):
        var expected = blocked_state
        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](expected, ActorStatus.READY):
            self.ready_queue[].push(actor)

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

    # check if an actor runs a TRANSFORM_MANY stage
    def actor_is_transform_many(self, actor: ActorDescriptor) -> Bool:
        comptime for i in range(len(Self.Ts)):
            if actor.stage_idx == i:
                comptime if Self.Ts[i].StageT.kind == StageKind.TRANSFORM_MANY:
                    return True
                else:
                    return False
        return False

    # try to wake an actor waiting on its input queue
    def wake_one_input_waiter(mut self, comm_idx: Int):
        while True:
            var maybe_actor = self.wq_inputs[comm_idx].try_pop()
            if not maybe_actor:
                return
            var actor = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_INPUT
            if self.actor_states[actor.flat_id].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.ready_queue[].push(actor)
                return

    # try to wake all actors waiting on the same input queue
    def wake_all_input_waiters(mut self, comm_idx: Int):
        while True:
            var maybe_actor = self.wq_inputs[comm_idx].try_pop()
            if not maybe_actor:
                return
            var actor = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_INPUT
            if self.actor_states[actor.flat_id].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.ready_queue[].push(actor)

    # try to wake actors waiting on the same output queue
    def wake_downstream_input_waiters(mut self, actor: ActorDescriptor):
        if actor.stage_idx >= self.num_stages - 1: # return if it is a sink
            return
        var comm_idx = self.output_wait_queue_idx(actor)
        if self.actor_is_transform_many(actor):
            self.wake_all_input_waiters(comm_idx)
        else:
            self.wake_one_input_waiter(comm_idx)

    # try to wake an actor waiting on its output queue
    def wake_one_output_waiter(mut self, comm_idx: Int):
        while True:
            var maybe_actor = self.wq_outputs[comm_idx].try_pop()
            if not maybe_actor:
                return
            var actor = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_OUTPUT
            if self.actor_states[actor.flat_id].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.ready_queue[].push(actor)
                return

    # force waiting some actors on the input queue to make room for new waiters
    def try_make_room_input(mut self, comm_idx: Int, max_pops: Int):
        for _ in range(max_pops):
            var maybe_actor = self.wq_inputs[comm_idx].try_pop()
            if not maybe_actor:
                return
            var stale = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_INPUT
            if self.actor_states[stale.flat_id].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.ready_queue[].push(stale)
                return

    # force waiting some actors on the output queue to make room for new waiters
    def try_make_room_output(mut self, comm_idx: Int, max_pops: Int):
        for _ in range(max_pops):
            var maybe_actor = self.wq_outputs[comm_idx].try_pop()
            if not maybe_actor:
                return
            var stale = maybe_actor.take()
            var expected = ActorStatus.BLOCKED_OUTPUT
            if self.actor_states[stale.flat_id].compare_exchange[
                success_ordering=Ordering.ACQUIRE_RELEASE,
                failure_ordering=Ordering.RELAXED]
                (expected, ActorStatus.READY):
                self.ready_queue[].push(stale)
                return

    # put the actor in the BLOCKING_INPUT state or mark it ready if already available
    def park_on_input_or_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        if actor.stage_idx == 0:
            self.mark_ready(actor)
            return
        var comm_idx = self.input_wait_queue_idx(actor)
        self.set_busy(actor) # protect
        var expected = ActorStatus.RUNNING
        if not self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.BLOCKED_INPUT):
            self.set_not_busy(actor) # unprotect
            return
        var not_queued = self.wq_inputs[comm_idx].try_push(actor)
        if not_queued:
            self.try_make_room_input(comm_idx, 8)
            not_queued = self.wq_inputs[comm_idx].try_push(actor)
        if not_queued:
            self.mark_blocked_ready(actor, ActorStatus.BLOCKED_INPUT)
            self.set_not_busy(actor) # unprotect
            return
        if self.try_reserve_input_for_actor(nodes, actor):
            self.wake_one_output_waiter(comm_idx)
            self.mark_blocked_ready(actor, ActorStatus.BLOCKED_INPUT)
            self.set_not_busy(actor) # unprotect
            return
        if self.actor_input_is_closed(nodes, actor):
            self.mark_blocked_ready(actor, ActorStatus.BLOCKED_INPUT)
        self.set_not_busy(actor) # unprotect

    # put the actor in the BLOCKING_OUTPUT state or mark it ready if already available
    def park_on_output_or_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        var comm_idx = self.output_wait_queue_idx(actor)
        self.set_busy(actor) # protect
        var expected = ActorStatus.RUNNING
        if not self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.BLOCKED_OUTPUT):
            self.set_not_busy(actor) # unprotect
            return
        var not_queued = self.wq_outputs[comm_idx].try_push(actor)
        if not_queued:
            self.try_make_room_output(comm_idx, 8)
            not_queued = self.wq_outputs[comm_idx].try_push(actor)
        if not_queued:
            self.mark_blocked_ready(actor, ActorStatus.BLOCKED_OUTPUT)
            self.set_not_busy(actor) # unprotect
            return
        if self.retry_push_pending_output_for_actor(nodes, actor):
            self.wake_one_input_waiter(comm_idx)
            self.mark_blocked_ready(actor, ActorStatus.BLOCKED_OUTPUT)
        self.set_not_busy(actor) # unprotect

    # notification method after processing an actor returning READY
    def notify_after_ready_activation(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # the actor might have consumed an input, capacity may have been freed upstream
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor))
        # the actor might have produced output(s), data may be available downstream
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_downstream_input_waiters(actor)

    # notification method after processing an actor returning BLOCKED_INPUT
    def notify_after_blocked_input(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # the actor might have produced output(s), data may be available downstream
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_downstream_input_waiters(actor)

    # notification method after processing an actor returning BLOCKED_OUTPUT
    def notify_after_blocked_output(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # the actor might have consumed an input, capacity may have been freed upstream
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor))
        # the actor may also have emitted other outputs before blocking, if the stage is TRANSFORM_MANY
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_downstream_input_waiters(actor)

    # notification method after processing an actor returning DONE
    def notify_after_done(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # a DONE transform/sink may have consumed input or observed EOS. Waking an
        # upstream producer is harmless and can release capacity waiters
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor))
        # a DONE source/transform may have closed its output communicator. If it is
        # closed, all downstream input waiters must be woken so they can observe EOS
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            if self.actor_output_is_closed(nodes, actor):
                self.wake_all_input_waiters(self.output_wait_queue_idx(actor))
            else:
                self.wake_downstream_input_waiters(actor)

    # main worker loop
    async
    def worker_loop(mut self, mut nodes: Tuple[*Self.Ts], core_id: Int, mut pinning_handler: Pinning):
        try:
            # pinning of the underlying thread if pinning is enabled
            if (core_id >= 0):
                _ = pinning_handler.pin_on_the_core(core_id)
            while self.done_count[].load[ordering=Ordering.ACQUIRE]() < UInt64(self.total_actors):
                var maybe_actor = self.ready_queue[].try_pop()
                if not maybe_actor:
                    continue
                var actor = maybe_actor.take()
                if not self.try_start_actor(actor):
                    continue
                self.spin_until_not_busy(actor) # to avoid inter-mixing with the parking logic
                var result = self.process_actor(nodes, actor)
                if result == ActorStatus.READY:
                    self.notify_after_ready_activation(nodes, actor)
                    self.mark_ready(actor)
                elif result == ActorStatus.BLOCKED_INPUT:
                    self.notify_after_blocked_input(nodes, actor)
                    self.park_on_input_or_ready(nodes, actor)
                elif result == ActorStatus.BLOCKED_OUTPUT:
                    self.notify_after_blocked_output(nodes, actor)
                    self.park_on_output_or_ready(nodes, actor)
                elif result == ActorStatus.DONE:
                    self.notify_after_done(nodes, actor)
                    self.mark_done(actor)
                else:
                    self.mark_done(actor)
        except e:
            print("Raised: " + String(e))
            exit(1)
