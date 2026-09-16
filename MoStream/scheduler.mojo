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

struct AdaptiveConfig:
    var initial_active: Int
    var min_active: Int
    var input_high_percent: Int
    var input_low_percent: Int
    var output_low_percent: Int
    var output_high_percent: Int
    var control_period_activations: Int
    var cooldown_periods: UInt64
    var shrink_streak_periods: UInt64

    # constructor
    def __init__(out self):
        self.initial_active = 1
        self.min_active = 1
        self.input_high_percent = 60
        self.input_low_percent = 20
        self.output_low_percent = 40
        self.output_high_percent = 80
        self.control_period_activations = 256
        self.cooldown_periods = UInt64(3) # delay between two consecutive parallelism changes for the same stage
        self.shrink_streak_periods = UInt64(3)

# Scheduler
struct Scheduler[*Ts: NodeTrait]:
    var num_stages: Int # number of stages in the pipeline
    var total_actors: Int # total number of actors in the pipeline (sum of parallelism degrees of all stages)
    var ready_queue: Pointer[MPMCQueue[ActorDescriptor], MutUntrackedOrigin] # ready queue for actors that are ready to run
    var wq_inputs: Pointer[MPMCQueue[ActorDescriptor], MutUntrackedOrigin] # array of wait queues for actors waiting on input
    var wq_outputs: Pointer[MPMCQueue[ActorDescriptor], MutUntrackedOrigin] # array of wait queues for actors waiting on output
    var actor_states: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic variables representing the state of each actor
    var done_count: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # counter of actors that have finished execution
    var actor_busy: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic flags to protect parking logic

    # adaptive scheduling fields
    var adaptive_active: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic variables representing the number of active actors for each stage
    var adaptive_target: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic variables representing the target number of active actors for each stage (use for lazy parallelism shrinking)
    var adaptive_shrink_streak: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic variables representing the number of consecutive periods where the stage is eligible for parallelism shrinking
    var adaptive_last_change_tick: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # array of atomic variables representing the last tick when the stage's parallelism was changed
    var adaptive_tick: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # atomic variable representing the current clock counter for adaptive scheduling
    var adaptive_lock: Pointer[Atomic[DType.uint64], MutUntrackedOrigin] # atomic variable to protect adaptive scheduling logic (one controller instance at a time)

    # constructor
    def __init__(out self, mut nodes: Tuple[*Self.Ts]) raises:
        self.num_stages = len(Self.Ts)
        self.total_actors = 0
        comptime for i in range(len(Self.Ts)):
            self.total_actors += nodes[i].parallelism()
        self.ready_queue = unsafe_alloc[MPMCQueue[ActorDescriptor]](1)
        self.ready_queue.unsafe_write(MPMCQueue[ActorDescriptor](1048576))
        self.wq_inputs = unsafe_alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
        self.wq_outputs = unsafe_alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
        for i in range(self.num_stages):
            self.wq_inputs.unsafe_offset(i).unsafe_write(MPMCQueue[ActorDescriptor](1048576))
            self.wq_outputs.unsafe_offset(i).unsafe_write(MPMCQueue[ActorDescriptor](1048576))
        self.actor_states = unsafe_alloc[Atomic[DType.uint64]](self.total_actors)
        for i in range(self.total_actors):
            self.actor_states.unsafe_offset(i)[] = Atomic[DType.uint64](ActorStatus.READY)
        self.done_count = unsafe_alloc[Atomic[DType.uint64]](1)
        self.done_count[] = Atomic[DType.uint64](0)
        self.actor_busy = unsafe_alloc[Atomic[DType.uint64]](self.total_actors)
        for i in range(self.total_actors):
            self.actor_busy.unsafe_offset(i)[] = Atomic[DType.uint64](0)
        self.adaptive_active = unsafe_alloc[Atomic[DType.uint64]](self.num_stages)
        self.adaptive_target = unsafe_alloc[Atomic[DType.uint64]](self.num_stages)
        self.adaptive_shrink_streak = unsafe_alloc[Atomic[DType.uint64]](self.num_stages)
        self.adaptive_last_change_tick = unsafe_alloc[Atomic[DType.uint64]](self.num_stages)
        for i in range(self.num_stages):
            self.adaptive_active.unsafe_offset(i)[] = Atomic[DType.uint64](0)
            self.adaptive_target.unsafe_offset(i)[] = Atomic[DType.uint64](0)
            self.adaptive_shrink_streak.unsafe_offset(i)[] = Atomic[DType.uint64](0)
            self.adaptive_last_change_tick.unsafe_offset(i)[] = Atomic[DType.uint64](0)
        self.adaptive_tick = unsafe_alloc[Atomic[DType.uint64]](1)
        self.adaptive_tick[] = Atomic[DType.uint64](0)
        self.adaptive_lock = unsafe_alloc[Atomic[DType.uint64]](1)
        self.adaptive_lock[] = Atomic[DType.uint64](0)

    # destructor
    def __deinit__(deinit self):
        self.ready_queue.unsafe_deinit_pointee()
        self.ready_queue.unsafe_free()
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
        for i in range(self.num_stages):
            self.adaptive_active.unsafe_offset(i).unsafe_deinit_pointee()
            self.adaptive_target.unsafe_offset(i).unsafe_deinit_pointee()
            self.adaptive_shrink_streak.unsafe_offset(i).unsafe_deinit_pointee()
            self.adaptive_last_change_tick.unsafe_offset(i).unsafe_deinit_pointee()
        self.adaptive_active.unsafe_free()
        self.adaptive_target.unsafe_free()
        self.adaptive_shrink_streak.unsafe_free()
        self.adaptive_last_change_tick.unsafe_free()
        self.adaptive_tick.unsafe_deinit_pointee()
        self.adaptive_tick.unsafe_free()
        self.adaptive_lock.unsafe_deinit_pointee()
        self.adaptive_lock.unsafe_free()

    # compute flat actor id from stage and replica without storing offsets
    def flat_actor_id(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int, replica_idx: Int) -> Int:
        var flat_id = 0
        comptime for i in range(len(Self.Ts)):
            if i < stage_idx:
                flat_id += nodes[i].parallelism()
        return flat_id + replica_idx

    # enqueue all actors, preserving the current cooperative behavior
    def enqueue_all_actors(mut self, mut nodes: Tuple[*Self.Ts]):
        comptime for i in range(len(Self.Ts)):
            var par_degree = nodes[i].parallelism()
            for j in range(par_degree):
                var flat_id = self.flat_actor_id(nodes, i, j)
                self.ready_queue[].push(ActorDescriptor(stage_idx=i, replica_idx=j, flat_id=flat_id))

    # enqueue only the active prefix of each stage for adaptive mode
    def enqueue_initial_adaptive_actors(mut self, mut nodes: Tuple[*Self.Ts], config: AdaptiveConfig):
        comptime for i in range(len(Self.Ts)):
            var max_degree = nodes[i].parallelism()
            var initial = config.initial_active
            # recommended minimal first version: do not adapt the source stage
            if i == 0:
                initial = max_degree
            if initial < config.min_active:
                initial = config.min_active
            if initial > max_degree:
                initial = max_degree
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_active.unsafe_offset(i)[].value), UInt64(initial))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_target.unsafe_offset(i)[].value), UInt64(initial))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_shrink_streak.unsafe_offset(i)[].value), UInt64(0))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_last_change_tick.unsafe_offset(i)[].value), UInt64(0))
            for j in range(initial):
                var flat_id = self.flat_actor_id(nodes, i, j)
                self.ready_queue[].push(ActorDescriptor(stage_idx=i, replica_idx=j, flat_id=flat_id))

    # start the scheduler in normal cooperative mode
    def start(mut self, mut nodes: Tuple[*Self.Ts], n_workers: Int, mut coreslist: CoresList):
        self.enqueue_all_actors(nodes)
        var tg = TaskGroup()
        for _ in range(0, n_workers):
            var core_id = coreslist.get_next_core_id()
            var task = self.worker_loop(nodes, core_id)
            tg.create_task(task^)
        tg.wait()

    # start the scheduler in adaptive cooperative mode
    def start_adaptive(mut self, mut nodes: Tuple[*Self.Ts], n_workers: Int, mut coreslist: CoresList, config: AdaptiveConfig):
        self.enqueue_initial_adaptive_actors(nodes, config)
        var tg = TaskGroup()
        for _ in range(0, n_workers):
            var core_id = coreslist.get_next_core_id()
            var task = self.worker_loop_adaptive(nodes, core_id, config)
            tg.create_task(task^)
        tg.wait()

    # compute input pressure of a stage as a percentage in [0, 100]
    def stage_input_pressure(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) raises -> Int:
        if stage_idx == 0:
            return 0
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                return nodes[i].actor_ref(0)[].in_comm[].pressure_percent()
        return 0

    # compute output pressure of a stage as a percentage in [0, 100]
    def stage_output_pressure(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) raises -> Int:
        if stage_idx == self.num_stages - 1:
            return 0
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                return nodes[i].actor_ref(0)[].out_comm[].pressure_percent()
        return 0

    # check if the input of a stage is drained (i.e., no more messages will be sent to it)
    def stage_input_is_drained(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) raises -> Bool:
        if stage_idx == 0:
            return False
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                return nodes[i].actor_ref(0)[].in_comm[].is_drained()
        return False

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

    # activate a quiet actor (adaptive cooperative scheduling)
    def activate_one_actor(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) -> Bool:
        var active = self.adaptive_active.unsafe_offset(stage_idx)[].load[ordering=Ordering.ACQUIRE]()
        var max_degree: UInt64 = 0
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                max_degree = UInt64(nodes[i].parallelism())
        if active >= max_degree:
            return False
        var replica_idx = Int(active)
        var flat_id = self.flat_actor_id(nodes, stage_idx, replica_idx)
        # the quiet actor is already READY; it is merely absent from ready_queue
        var expected = active
        if self.adaptive_active.unsafe_offset(stage_idx)[].compare_exchange[
            success_ordering=Ordering.ACQUIRE_RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](expected, active + UInt64(1)):
            self.ready_queue[].push(ActorDescriptor(stage_idx=stage_idx, replica_idx=replica_idx, flat_id=flat_id))
            return True
        return False

    # check if the actor can be quieted (adaptive cooperative scheduling)
    def should_quiet_after_ready(mut self, actor: ActorDescriptor, config: AdaptiveConfig) -> Bool:
        if actor.stage_idx == 0:
            return False # source adaptation disabled in the first version
        var active = self.adaptive_active.unsafe_offset(actor.stage_idx)[].load[ordering=Ordering.ACQUIRE]()
        var target = self.adaptive_target.unsafe_offset(actor.stage_idx)[].load[ordering=Ordering.ACQUIRE]()
        if active <= target:
            return False
        if active <= UInt64(config.min_active):
            return False
        # Prefix invariant: only the highest active replica can be removed
        return actor.replica_idx == Int(active - UInt64(1))

    # mark a running actor as quiet (adaptive cooperative scheduling)
    def mark_from_running_to_quiet_ready(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](expected, ActorStatus.READY):
            _ = self.adaptive_active.unsafe_offset(actor.stage_idx)[].fetch_sub[ordering=Ordering.ACQUIRE_RELEASE](UInt64(1))

    #  activate all quiet actors for drained stages
    def activate_all_quiet_actors_for_drained_stages(mut self, mut nodes: Tuple[*Self.Ts]) raises:
        comptime for i in range(len(Self.Ts)):
            if i == 0:
                continue
            if not self.stage_input_is_drained(nodes, i):
                continue
            var max_degree = nodes[i].parallelism()
            var active = self.adaptive_active.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            while active < UInt64(max_degree):
                if not self.activate_one_actor(nodes, i):
                    return
                active = self.adaptive_active.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_target.unsafe_offset(i)[].value), UInt64(max_degree))

    # mark a running actor as ready to run
    def mark_from_running_to_ready(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.READY):
            self.ready_queue[].push(actor)

    # mark a running actor as done
    def mark_from_running_to_done(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED]
            (expected, ActorStatus.DONE):
            _ = self.done_count[].fetch_add[ordering=Ordering.ACQUIRE_RELEASE](1) # ordering is safer, RELEASE should be still fine

    # mark a blocked actor (BLOCKED_INPUT or BLOCKED_OUTPUT) as ready to run
    def mark_from_blocked_to_ready(mut self, actor: ActorDescriptor, blocked_state: UInt64):
        var expected = blocked_state
        if self.actor_states.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](expected, ActorStatus.READY):
            self.ready_queue[].push(actor)

    # set an actor as busy (to protect parking logic)
    def set_busy(mut self, actor: ActorDescriptor) raises:
        var expected = UInt64(0) # non-busy
        if not self.actor_busy.unsafe_offset(actor.flat_id)[].compare_exchange[
            success_ordering=Ordering.ACQUIRE_RELEASE, # ordering is safer, RELEASE should be still fine
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
    def wake_one_input_waiter(mut self, comm_idx: Int):
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
                self.ready_queue[].push(actor)
                return

    # try to wake all actors waiting on the same input queue
    def wake_all_input_waiters(mut self, comm_idx: Int):
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
                self.ready_queue[].push(actor)

    # try to wake an actor waiting on its output queue
    def wake_one_output_waiter(mut self, comm_idx: Int):
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
                self.ready_queue[].push(actor)
                return

    # force waiting some actors on the input queue to make room for new waiters
    def try_make_room_input(mut self, comm_idx: Int, max_pops: Int):
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
                self.ready_queue[].push(stale)
                return

    # force waiting some actors on the output queue to make room for new waiters
    def try_make_room_output(mut self, comm_idx: Int, max_pops: Int):
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
                self.ready_queue[].push(stale)
                return

    # put the actor in the BLOCKING_INPUT state or mark it ready if already available
    def park_on_input_or_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        if actor.stage_idx == 0:
            self.mark_from_running_to_ready(actor)
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
            self.try_make_room_input(comm_idx, 8)
            not_queued = self.wq_inputs.unsafe_offset(comm_idx)[].try_push(actor)
        if not_queued:
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_INPUT)
            self.set_not_busy(actor) # unprotect
            return
        if self.try_reserve_input_for_actor(nodes, actor):
            self.wake_one_output_waiter(comm_idx)
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_INPUT)
            self.set_not_busy(actor) # unprotect
            return
        if self.actor_input_is_closed(nodes, actor):
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_INPUT)
        self.set_not_busy(actor) # unprotect

    # put the actor in the BLOCKING_OUTPUT state or mark it ready if already available
    def park_on_output_or_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
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
            self.try_make_room_output(comm_idx, 8)
            not_queued = self.wq_outputs.unsafe_offset(comm_idx)[].try_push(actor)
        if not_queued:
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_OUTPUT)
            self.set_not_busy(actor) # unprotect
            return
        if self.retry_push_pending_output_for_actor(nodes, actor):
            self.wake_one_input_waiter(comm_idx)
            self.mark_from_blocked_to_ready(actor, ActorStatus.BLOCKED_OUTPUT)
        self.set_not_busy(actor) # unprotect

    # notification method after processing an actor returning READY
    def notify_after_ready(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # the actor might have consumed an input, capacity may have been freed upstream
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor))
        # the actor might have produced output(s), data may be available downstream
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_one_input_waiter(self.output_wait_queue_idx(actor))

    # notification method after processing an actor returning BLOCKED_INPUT
    def notify_after_blocked_input(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # the actor might have produced output(s), data may be available downstream
        if actor.stage_idx < self.num_stages - 1: # if it is not a sink
            self.wake_one_input_waiter(self.output_wait_queue_idx(actor))

    # notification method after processing an actor returning BLOCKED_OUTPUT
    def notify_after_blocked_output(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises:
        # the actor might have consumed an input, capacity may have been freed upstream
        if actor.stage_idx > 0: # if it is not a source
            self.wake_one_output_waiter(self.input_wait_queue_idx(actor))

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
                self.wake_one_input_waiter(self.output_wait_queue_idx(actor))

    # main worker loop
    async def worker_loop(mut self, mut nodes: Tuple[*Self.Ts], core_id: Int):
        try:
            # pinning of the underlying thread if pinning is enabled
            _ = pin_thread_to_cpu(core_id)
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
                    self.notify_after_ready(nodes, actor)
                    self.mark_from_running_to_ready(actor)
                elif result == ActorStatus.BLOCKED_INPUT:
                    self.notify_after_blocked_input(nodes, actor)
                    self.park_on_input_or_ready(nodes, actor)
                elif result == ActorStatus.BLOCKED_OUTPUT:
                    self.notify_after_blocked_output(nodes, actor)
                    self.park_on_output_or_ready(nodes, actor)
                elif result == ActorStatus.DONE:
                    self.notify_after_done(nodes, actor)
                    self.mark_from_running_to_done(actor)
                else:
                    self.mark_from_running_to_done(actor)
        except e:
            print("Raised: " + String(e))
            exit(1)

    # worker main loop (adaptive cooperative scheduling)
    async def worker_loop_adaptive(mut self,
                                   mut nodes: Tuple[*Self.Ts],
                                   core_id: Int,
                                   config: AdaptiveConfig):
        try:
            # pinning of the underlying thread if pinning is enabled
            _ = pin_thread_to_cpu(core_id)
            while self.done_count[].load[ordering=Ordering.ACQUIRE]() < UInt64(self.total_actors):
                var maybe_actor = self.ready_queue[].try_pop()
                if not maybe_actor:
                    self.activate_all_quiet_actors_for_drained_stages(nodes)
                    self.maybe_run_adaptive_controller(nodes, config)
                    continue
                var actor = maybe_actor.take()
                if not self.try_start_actor(actor):
                    continue
                self.spin_until_not_busy(actor)
                var result = self.process_actor(nodes, actor)
                if result == ActorStatus.READY:
                    self.notify_after_ready(nodes, actor)
                    if self.should_quiet_after_ready(actor, config):
                        self.mark_from_running_to_quiet_ready(actor)
                    else:
                        self.mark_from_running_to_ready(actor)
                elif result == ActorStatus.BLOCKED_INPUT:
                    self.notify_after_blocked_input(nodes, actor)
                    self.park_on_input_or_ready(nodes, actor)
                elif result == ActorStatus.BLOCKED_OUTPUT:
                    self.notify_after_blocked_output(nodes, actor)
                    self.park_on_output_or_ready(nodes, actor)
                elif result == ActorStatus.DONE:
                    self.notify_after_done(nodes, actor)
                    self.mark_from_running_to_done(actor)
                    if actor.stage_idx < self.num_stages - 1:
                        self.activate_all_quiet_actors_for_drained_stages(nodes)
                else:
                    self.mark_from_running_to_done(actor)
                self.maybe_run_adaptive_controller(nodes, config)
        except e:
            print("Raised: " + String(e))
            exit(1)

    # check if we need to run the controller (adaptive cooperative scheduling)
    def maybe_run_adaptive_controller(mut self, mut nodes: Tuple[*Self.Ts], config: AdaptiveConfig) raises:
        var tick = self.adaptive_tick[].fetch_add[ordering=Ordering.ACQUIRE_RELEASE](UInt64(1))
        if tick % UInt64(config.control_period_activations) != UInt64(0):
            return
        var expected = UInt64(0)
        if not self.adaptive_lock[].compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED,
        ](expected, UInt64(1)):
            return
        self.run_adaptive_controller(nodes, config, tick)
        Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_lock[].value), UInt64(0))

    # controller (adaptive cooperative scheduler)
    def run_adaptive_controller(mut self, mut nodes: Tuple[*Self.Ts], config: AdaptiveConfig, tick: UInt64) raises:
        var chosen_stage = -1
        var chosen_score = -1
        # first pass: find strongest bottleneck to scale up
        comptime for i in range(len(Self.Ts)):
            if i == 0:
                continue # source adaptation disabled in first version
            if self.stage_input_is_drained(nodes, i):
                continue
            var max_degree = nodes[i].parallelism()
            var target = self.adaptive_target.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            if target >= UInt64(max_degree):
                continue
            var last_change = self.adaptive_last_change_tick.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            if tick < last_change + UInt64(config.cooldown_periods) * UInt64(config.control_period_activations):
                continue
            var input_p = self.stage_input_pressure(nodes, i)
            var output_p = self.stage_output_pressure(nodes, i)
            var is_bottleneck = input_p >= config.input_high_percent and output_p <= config.output_low_percent
            if is_bottleneck:
                var score = input_p - output_p
                if score > chosen_score:
                    chosen_score = score
                    chosen_stage = i
        if chosen_stage >= 0:
            var old_target = self.adaptive_target.unsafe_offset(chosen_stage)[].load[ordering=Ordering.ACQUIRE]()
            var input_p = self.stage_input_pressure(nodes, chosen_stage)
            var output_p = self.stage_output_pressure(nodes, chosen_stage)
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_target.unsafe_offset(chosen_stage)[].value), old_target + UInt64(1))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_shrink_streak.unsafe_offset(chosen_stage)[].value), UInt64(0))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_last_change_tick.unsafe_offset(chosen_stage)[].value), tick)
            _ = self.activate_one_actor(nodes, chosen_stage)
            #self.print_adaptive_parallelism(nodes, String("grow"), chosen_stage, old_target, old_target + UInt64(1), input_p, output_p, tick)
            return
        # second pass: if no bottleneck was scaled up, choose one stable shrink
        comptime for i in range(len(Self.Ts)):
            if i == 0:
                continue # source adaptation disabled in first version
            if self.stage_input_is_drained(nodes, i):
                continue
            var target = self.adaptive_target.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            if target <= UInt64(config.min_active):
                continue

            var active = self.adaptive_active.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            if active > target:
                continue

            var last_change = self.adaptive_last_change_tick.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            if tick < last_change + UInt64(config.cooldown_periods) * UInt64(config.control_period_activations):
                continue
            var input_p = self.stage_input_pressure(nodes, i)
            var output_p = self.stage_output_pressure(nodes, i)
            var should_shrink = input_p <= config.input_low_percent or output_p >= config.output_high_percent
            if should_shrink:
                var streak = self.adaptive_shrink_streak.unsafe_offset(i)[].fetch_add[ordering=Ordering.ACQUIRE_RELEASE](UInt64(1)) + UInt64(1)
                if streak >= config.shrink_streak_periods:
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_target.unsafe_offset(i)[].value), target - UInt64(1))
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_shrink_streak.unsafe_offset(i)[].value), UInt64(0))
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_last_change_tick.unsafe_offset(i)[].value), tick)
                    #self.print_adaptive_parallelism(nodes, String("shrink"), i, target, target - UInt64(1), input_p, output_p, tick)
                    return
            else:
                Atomic[DType.uint64].store[ordering=Ordering.RELEASE](Pointer(to=self.adaptive_shrink_streak.unsafe_offset(i)[].value), UInt64(0))

    # debug method to print the current adaptive state
    def print_adaptive_parallelism(mut self, mut nodes: Tuple[*Self.Ts], action: String, changed_stage: Int, old_target: UInt64, new_target: UInt64, input_p: Int, output_p: Int, tick: UInt64):
        print(
            "[adaptive] tick=" + String(tick)
            + " " + action
            + " stage=" + String(changed_stage)
            + " target=" + String(old_target) + "->" + String(new_target)
            + " pressure(in/out)=" + String(input_p) + "%/" + String(output_p) + "%"
        )
        var state_line = "           active/target/max:"
        comptime for i in range(len(Self.Ts)):
            var active = self.adaptive_active.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            var target = self.adaptive_target.unsafe_offset(i)[].load[ordering=Ordering.ACQUIRE]()
            var max_degree = nodes[i].parallelism()
            var marker = " "
            if i == changed_stage:
                marker = "*"
            state_line += " | " + marker + "S" + String(i) + "=" + String(active) + "/" + String(target) + "/" + String(max_degree)
        print(state_line)
