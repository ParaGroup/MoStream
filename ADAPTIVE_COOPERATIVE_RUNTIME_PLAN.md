# Minimal Adaptive Cooperative Runtime Guide

This guide describes the minimal code changes needed to add
`run_cooperative_adaptive` while keeping a single scheduler and keeping the
actor state machine unchanged.

The important design decisions are:

- There is only one scheduler: `Scheduler` in `MoStream/scheduler.mojo`.
- Actor states remain exactly:
  - `READY`
  - `RUNNING`
  - `BLOCKED_INPUT`
  - `BLOCKED_OUTPUT`
  - `DONE`
- There is no `PAUSED` state.
- A deactivated actor is a `READY` actor that is not present in `ready_queue`.
- All actors are created at startup from the per-stage maximum parallelism.
- Adaptive mode controls only how many stage actors are currently enqueued or
  allowed to re-enter `ready_queue`.
- A stage is a bottleneck when its input pressure is high and its output
  pressure is low.
- Scale-down is lazy: when an actor returns `READY`, the scheduler can decide
  not to push it back into `ready_queue`.

The strategy below intentionally uses a prefix invariant to avoid per-actor
adaptive flags.

For each stage:

```text
replicas [0, active_count) are active
replicas [active_count, max_parallelism) are quiet READY actors
```

Because inactive actors are always a suffix, the scheduler can activate the next
actor by enqueuing replica `active_count`, and can safely deactivate only the
last active replica, `active_count - 1`, after it returns `READY`.

## Minimal Extra Scheduler Fields

Add only these fields to `Scheduler` in `MoStream/scheduler.mojo`:

```mojo
var adaptive_active: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
var adaptive_target: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
var adaptive_shrink_streak: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
var adaptive_last_change_tick: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
var adaptive_tick: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
var adaptive_lock: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
```

Meaning:

- `adaptive_active[i]`: active prefix length for stage `i`.
- `adaptive_target[i]`: desired active prefix length selected by the controller.
- `adaptive_shrink_streak[i]`: consecutive control periods where stage `i`
  looked over-provisioned.
- `adaptive_last_change_tick[i]`: last controller tick that changed stage `i`.
- `adaptive_tick`: global adaptive controller period counter.
- `adaptive_lock`: lets only one worker run the controller at a time.

No additional scheduler fields are required for:

- max parallelism: use `nodes[i].parallelism()`
- actor offsets: compute them when needed
- per-stage done counts: use existing global `done_count`
- inactive state: quiet actors are just `READY` and not queued
- mode flag: use a separate `start_adaptive` and `worker_loop_adaptive`

## 1. Queue And Communicator Metrics

### File: `MoStream/MPMC_queue.mojo`

Fix `estimated_len()` and add `capacity()`.

Replace the existing `estimated_len()` with:

```mojo
    # returns an estimate of the current number of items in the queue
    def estimated_len(self) -> Int:
        var enq = self.enqueue_pos.atomicVal.load[ordering=Ordering.RELAXED]()
        var deq = self.dequeue_pos.atomicVal.load[ordering=Ordering.RELAXED]()
        if enq <= deq:
            return 0
        var diff = enq - deq
        if diff > self.size:
            return Int(self.size)
        return Int(diff)
```

Add just after it:

```mojo
    # returns the bounded queue capacity
    def capacity(self) -> Int:
        return Int(self.size)
```

### File: `MoStream/communicator.mojo`

Add these methods at the end of `Communicator`:

```mojo
    # get the bounded communicator capacity
    def capacity(self) -> Int:
        return self.queue[].capacity()

    # get estimated queue pressure as a percentage in [0, 100]
    def pressure_percent(mut self) -> Int:
        var cap = self.capacity()
        if cap <= 0:
            return 0
        return (100 * self.estimated_len()) // cap

    # true when no more real messages can arrive and the queue is empty
    def is_drained(mut self) -> Bool:
        return self.is_closed() and self.estimated_len() == 0
```

## 2. Adaptive Configuration

### File: `MoStream/scheduler.mojo`

Add near the top, after `ActorDescriptor`:

```mojo
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

    def __init__(out self):
        self.initial_active = 1
        self.min_active = 1
        self.input_high_percent = 60
        self.input_low_percent = 20
        self.output_low_percent = 40
        self.output_high_percent = 80
        self.control_period_activations = 256
        self.cooldown_periods = UInt64(3)
        self.shrink_streak_periods = UInt64(3)
```

## 3. Scheduler Field Additions

### File: `MoStream/scheduler.mojo`

In `struct Scheduler[*Ts: NodeTrait]`, add the six fields:

```mojo
    var adaptive_active: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
    var adaptive_target: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
    var adaptive_shrink_streak: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
    var adaptive_last_change_tick: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
    var adaptive_tick: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
    var adaptive_lock: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
```

In `Scheduler.__init__`, allocate and initialize them after `actor_busy`:

```mojo
        self.adaptive_active = alloc[Atomic[DType.uint64]](self.num_stages)
        self.adaptive_target = alloc[Atomic[DType.uint64]](self.num_stages)
        self.adaptive_shrink_streak = alloc[Atomic[DType.uint64]](self.num_stages)
        self.adaptive_last_change_tick = alloc[Atomic[DType.uint64]](self.num_stages)

        for i in range(self.num_stages):
            (self.adaptive_active + i)[] = Atomic[DType.uint64](0)
            (self.adaptive_target + i)[] = Atomic[DType.uint64](0)
            (self.adaptive_shrink_streak + i)[] = Atomic[DType.uint64](0)
            (self.adaptive_last_change_tick + i)[] = Atomic[DType.uint64](0)

        self.adaptive_tick = alloc[Atomic[DType.uint64]](1)
        self.adaptive_tick[] = Atomic[DType.uint64](0)

        self.adaptive_lock = alloc[Atomic[DType.uint64]](1)
        self.adaptive_lock[] = Atomic[DType.uint64](0)
```

In `Scheduler.__del__`, free them:

```mojo
        for i in range(self.num_stages):
            (self.adaptive_active + i).destroy_pointee()
            (self.adaptive_target + i).destroy_pointee()
            (self.adaptive_shrink_streak + i).destroy_pointee()
            (self.adaptive_last_change_tick + i).destroy_pointee()
        self.adaptive_active.free()
        self.adaptive_target.free()
        self.adaptive_shrink_streak.free()
        self.adaptive_last_change_tick.free()

        self.adaptive_tick.destroy_pointee()
        self.adaptive_tick.free()
        self.adaptive_lock.destroy_pointee()
        self.adaptive_lock.free()
```

## 4. Refactor Scheduler Initialization

### File: `MoStream/scheduler.mojo`

The current constructor pushes every actor into `ready_queue`. Move that logic
into a helper, so normal cooperative mode can enqueue all actors and adaptive
mode can enqueue only an initial prefix.

In `__init__`, remove this push from the constructor loop:

```mojo
                self.ready_queue[].push(ActorDescriptor(stage_idx=i, replica_idx=j, flat_id=flat_id))
```

Keep the flat id counting, but do not enqueue actors there.

Then add:

```mojo
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

            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_active[i].value), UInt64(initial))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_target[i].value), UInt64(initial))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_shrink_streak[i].value), UInt64(0))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_last_change_tick[i].value), UInt64(0))

            for j in range(initial):
                var flat_id = self.flat_actor_id(nodes, i, j)
                self.ready_queue[].push(ActorDescriptor(stage_idx=i, replica_idx=j, flat_id=flat_id))
```

Notes:

- Every actor state remains `READY` after construction.
- Actors outside the active prefix are quiet `READY` actors.
- Source actors are not adapted in this first version; they all start active.
  This avoids changing source cardinality for stateful sources.

## 5. Normal And Adaptive Start Methods

### File: `MoStream/scheduler.mojo`

Modify current `start` to enqueue all actors before workers launch:

```mojo
    # start the scheduler in normal cooperative mode
    def start(mut self, mut nodes: Tuple[*Self.Ts], n_workers: Int, mut pinning_handler: Pinning):
        self.enqueue_all_actors(nodes)
        var tg = TaskGroup()
        for _ in range(0, n_workers):
            tg.create_task(self.worker_loop(nodes, pinning_handler.get_next_core_id(), pinning_handler))
        tg.wait()
```

Add adaptive start:

```mojo
    # start the scheduler in adaptive cooperative mode
    def start_adaptive(mut self, mut nodes: Tuple[*Self.Ts], n_workers: Int, mut pinning_handler: Pinning, config: AdaptiveConfig):
        self.enqueue_initial_adaptive_actors(nodes, config)
        var tg = TaskGroup()
        for _ in range(0, n_workers):
            tg.create_task(self.worker_loop_adaptive(nodes, pinning_handler.get_next_core_id(), pinning_handler, config))
        tg.wait()
```

If passing `AdaptiveConfig` into async tasks is awkward, store a copy of the
config as scheduler fields. That is slightly more state, so prefer passing it
first.

## 6. Pressure Helpers

### File: `MoStream/scheduler.mojo`

Add helpers that inspect communicator pressure through replica `0` of a stage.

```mojo
    def stage_input_pressure(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) raises -> Int:
        if stage_idx == 0:
            return 0
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                return nodes[i].actor_ref(0)[].in_comm[].pressure_percent()
        return 0

    def stage_output_pressure(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) raises -> Int:
        if stage_idx == self.num_stages - 1:
            return 0
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                return nodes[i].actor_ref(0)[].out_comm[].pressure_percent()
        return 0

    def stage_input_is_drained(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) raises -> Bool:
        if stage_idx == 0:
            return False
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                return nodes[i].actor_ref(0)[].in_comm[].is_drained()
        return False
```

## 7. Activation And Deactivation Helpers

### File: `MoStream/scheduler.mojo`

Add activation of quiet `READY` suffix actors:

```mojo
    def activate_one_actor(mut self, mut nodes: Tuple[*Self.Ts], stage_idx: Int) -> Bool:
        var active = self.adaptive_active[stage_idx].load[ordering=Ordering.ACQUIRE]()
        var max_degree: UInt64 = 0
        comptime for i in range(len(Self.Ts)):
            if stage_idx == i:
                max_degree = UInt64(nodes[i].parallelism())

        if active >= max_degree:
            return False

        var replica_idx = Int(active)
        var flat_id = self.flat_actor_id(nodes, stage_idx, replica_idx)

        # The quiet actor is already READY; it is merely absent from ready_queue.
        # Increment active first, then enqueue it.
        var expected = active
        if self.adaptive_active[stage_idx].compare_exchange[
            success_ordering=Ordering.ACQUIRE_RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](expected, active + UInt64(1)):
            self.ready_queue[].push(ActorDescriptor(stage_idx=stage_idx, replica_idx=replica_idx, flat_id=flat_id))
            return True
        return False
```

Add scale-down decision after `READY`:

```mojo
    def should_quiet_after_ready(mut self, actor: ActorDescriptor, config: AdaptiveConfig) -> Bool:
        if actor.stage_idx == 0:
            return False # source adaptation disabled in the first version

        var active = self.adaptive_active[actor.stage_idx].load[ordering=Ordering.ACQUIRE]()
        var target = self.adaptive_target[actor.stage_idx].load[ordering=Ordering.ACQUIRE]()

        if active <= target:
            return False
        if active <= UInt64(config.min_active):
            return False

        # Prefix invariant: only the highest active replica can be removed.
        return actor.replica_idx == Int(active - UInt64(1))
```

Add the actual deactivation:

```mojo
    def mark_from_running_to_quiet_ready(mut self, actor: ActorDescriptor):
        var expected = ActorStatus.RUNNING
        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](expected, ActorStatus.READY):
            _ = self.adaptive_active[actor.stage_idx].fetch_sub[ordering=Ordering.ACQUIRE_RELEASE](UInt64(1))
```

This is the entire deactivation operation. The actor state is `READY`, but the
descriptor is not pushed into `ready_queue`.

## 8. Adaptive Controller

### File: `MoStream/scheduler.mojo`

Add a small controller. It runs occasionally from worker threads.

```mojo
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
        Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_lock[].value), UInt64(0))
```

Add controller body:

```mojo
    def run_adaptive_controller(mut self, mut nodes: Tuple[*Self.Ts], config: AdaptiveConfig, tick: UInt64) raises:
        var chosen_stage = -1
        var chosen_score = -1

        # First pass: find strongest bottleneck to scale up.
        comptime for i in range(len(Self.Ts)):
            if i == 0:
                continue # source adaptation disabled in first version

            var max_degree = nodes[i].parallelism()
            var target = self.adaptive_target[i].load[ordering=Ordering.ACQUIRE]()
            if target >= UInt64(max_degree):
                continue

            var last_change = self.adaptive_last_change_tick[i].load[ordering=Ordering.ACQUIRE]()
            if tick < last_change + config.cooldown_periods:
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
            var old_target = self.adaptive_target[chosen_stage].load[ordering=Ordering.ACQUIRE]()
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_target[chosen_stage].value), old_target + UInt64(1))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_shrink_streak[chosen_stage].value), UInt64(0))
            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_last_change_tick[chosen_stage].value), tick)
            _ = self.activate_one_actor(nodes, chosen_stage)
            return

        # Second pass: if no bottleneck was scaled up, choose one stable shrink.
        comptime for i in range(len(Self.Ts)):
            if i == 0:
                continue # source adaptation disabled in first version

            var target = self.adaptive_target[i].load[ordering=Ordering.ACQUIRE]()
            if target <= UInt64(config.min_active):
                continue

            var last_change = self.adaptive_last_change_tick[i].load[ordering=Ordering.ACQUIRE]()
            if tick < last_change + config.cooldown_periods:
                continue

            var input_p = self.stage_input_pressure(nodes, i)
            var output_p = self.stage_output_pressure(nodes, i)

            var should_shrink = input_p <= config.input_low_percent or output_p >= config.output_high_percent
            if should_shrink:
                var streak = self.adaptive_shrink_streak[i].fetch_add[ordering=Ordering.ACQUIRE_RELEASE](UInt64(1)) + UInt64(1)
                if streak >= config.shrink_streak_periods:
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_target[i].value), target - UInt64(1))
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_shrink_streak[i].value), UInt64(0))
                    Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_last_change_tick[i].value), tick)
                    return
            else:
                Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_shrink_streak[i].value), UInt64(0))
```

This controller:

- scales up at most one stage per control pass
- scales down at most one stage per control pass
- prefers scaling bottlenecks up before shrinking anything
- uses cooldown and shrink streaks to reduce erratic behavior

## 9. Drain Quiet READY Actors

### File: `MoStream/scheduler.mojo`

Inactive suffix actors are `READY` but not queued. At EOS, transform and sink
actors in that suffix must still run once so they can observe virtual EOS and
become `DONE`. Otherwise `done_count` may never reach `total_actors`.

Add:

```mojo
    def activate_all_quiet_actors_for_drained_stages(mut self, mut nodes: Tuple[*Self.Ts]) raises:
        comptime for i in range(len(Self.Ts)):
            if i == 0:
                continue

            if not self.stage_input_is_drained(nodes, i):
                continue

            var max_degree = nodes[i].parallelism()
            var active = self.adaptive_active[i].load[ordering=Ordering.ACQUIRE]()
            while active < UInt64(max_degree):
                if not self.activate_one_actor(nodes, i):
                    return
                active = self.adaptive_active[i].load[ordering=Ordering.ACQUIRE]()

            Atomic[DType.uint64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.adaptive_target[i].value), UInt64(max_degree))
```

Call this from the adaptive controller and also when a worker finds no ready
actor:

```mojo
self.activate_all_quiet_actors_for_drained_stages(nodes)
```

This avoids adding any special actor finalization method.

## 10. Adaptive Worker Loop

### File: `MoStream/scheduler.mojo`

Add an adaptive worker loop by copying the existing `worker_loop` and changing
only the `READY` case plus the periodic controller call.

```mojo
    async
    def worker_loop_adaptive(mut self, mut nodes: Tuple[*Self.Ts], core_id: Int, mut pinning_handler: Pinning, config: AdaptiveConfig):
        try:
            if (core_id >= 0):
                _ = pinning_handler.pin_on_the_core(core_id)

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
```

The normal `worker_loop` remains unchanged.

## 11. Pipeline Entry Point

### File: `MoStream/pipeline.mojo`

Import `AdaptiveConfig`:

```mojo
from MoStream.scheduler import Scheduler, AdaptiveConfig
```

Add:

```mojo
    # run_cooperative_adaptive
    def run_cooperative_adaptive(mut self, n_workers: Int) raises:
        if (self.alreadyRun):
            print_red_color("{MoStream} Error: run(), run_cooperative() or run_cooperative_adaptive() can be called only once for each pipeline instance!")
            raise Error("error in run_cooperative_adaptive()")
        self.alreadyRun = True
        if (n_workers > parallelism_level()):
            print_red_color("{MoStream} Error: the number of workers of the adaptive cooperative scheduler is greater than the number threads available in the thread pool!")
            raise Error("error in run_cooperative_adaptive()")

        var pinning = "disabled"
        if self.pinning_handler.enabled:
            pinning = "enabled"

        var in_comm = UnsafePointer[Communicator[Self.Ts[0].StageT.InType], MutExternalOrigin].unsafe_dangling()
        out_comm = alloc[Communicator[Self.Ts[0].StageT.OutType]](1)
        out_comm.init_pointee_move(Communicator[Self.Ts[0].StageT.OutType](pN=self.nodes[0].parallelism(), cN=self.nodes[1].parallelism(), queue_size=self.queue_size))
        for _ in range(0, self.nodes[0].parallelism()):
            self.nodes[0].add_actor(Actor[Self.Ts[0].StageT](stage=self.nodes[0].make_stage(), in_comm=in_comm, out_comm=out_comm))
        self._run_cooperative_from[1, Self.N](out_comm)

        print_cyan_color("{MoStream} Starting pipeline execution with " + String(Self.N) + " stages and maximum total parallelism of " + String(self.getNumNodes()) + " nodes")
        print_cyan_color("{MoStream} Adaptive cooperative MoStream runtime is used")
        print_cyan_color("{MoStream} CPU pinning is " + pinning)
        print_cyan_color("{MoStream} Pipeline starts...")

        var scheduler = Scheduler(self.nodes)
        var config = AdaptiveConfig()
        scheduler.start_adaptive(self.nodes, n_workers, self.pinning_handler, config)
        print_cyan_color("{MoStream} ...terminated successfully!")
```

This intentionally reuses `_run_cooperative_from` and creates all actors exactly
as current cooperative mode does.

## 12. Optional Public Export

### File: `MoStream/__init__.mojo`

Only if users should tune config:

```mojo
from MoStream.scheduler import AdaptiveConfig
```

## 13. Important Invariants

Keep these invariants true:

1. Actor states are unchanged.
2. A quiet actor is `READY` but not in `ready_queue`.
3. Quiet actors are always a suffix of stage replicas.
4. Only replica `active_count` can be activated.
5. Only replica `active_count - 1` can be deactivated.
6. Deactivation happens only after `READY`.
7. Source stages are not adapted in the first version.
8. Quiet transform/sink actors are activated when their input communicator is
   drained so they can observe EOS normally.

These invariants are what let the implementation avoid adding per-actor active
flags or extra actor states.

## 14. Tests To Add

### File: `Tests/test_pipe_3_adaptive.mojo`

Clone `Tests/test_pipe_3_coop.mojo` and change:

```mojo
pipeline.run_cooperative(n_workers)
```

to:

```mojo
pipeline.run_cooperative_adaptive(n_workers)
```

Use max degrees greater than `n_workers` to confirm adaptive mode can run with
more logical actors than scheduler workers.

### Suggested checks

- Max degree 1 for every stage should behave like cooperative mode.
- High max degrees with few workers should terminate.
- A slow middle transform should scale up when its input queue fills and output
  queue stays low.
- A stage should not scale up when its output queue is high.
- Scale-down should occur only after several low-pressure periods.
- No actor should be deactivated from `BLOCKED_INPUT` or `BLOCKED_OUTPUT`.
- EOS should terminate every actor, including quiet `READY` actors.

## 15. Notes About `TRANSFORM_MANY`

Keep adaptive cooperative mode unsupported for `TRANSFORM_MANY` initially,
matching the current cooperative actor limitation.

Add an early check later if you want a clearer error message. Supporting
`TRANSFORM_MANY` adaptively would require non-blocking, resumable multi-output
emission, which is a separate design.
