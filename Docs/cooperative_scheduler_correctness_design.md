# Cooperative Scheduler Implementation Blueprint

This document is a method-level blueprint for adding cooperative scheduling to
MoStream.

It is intentionally separate from the official implementation. The code blocks
are Mojo-like code meant to show the needed fields, methods, ownership model,
and synchronization protocol. Some syntax may need small adjustments while
porting to the library.

The design reflects these decisions:

- The `Pipeline` owns the heterogeneous tuple of nodes.
- The `Scheduler` does not copy `Pipeline.nodes`.
- Scheduler queues contain actor descriptors, not actor objects.
- Actor state is authoritative; queue entries can be stale.
- Parking on input/output must recheck using only `try_pop()` and `try_push()`.
- EOS should be represented by communicator closure, not by pushing EOS tokens.

## Required Invariants

The most important invariant is:

```text
Queue membership is advisory.
The atomic actor state is authoritative.
```

This means:

```text
ready_queue may contain stale entries.
input wait queues may contain stale entries.
output wait queues may contain stale entries.
```

Before a scheduler worker runs an actor, it must prove ownership with:

```text
READY -> RUNNING
```

Before a wakeup makes a blocked actor runnable, it must prove that the actor is
still waiting with:

```text
WAITING_INPUT -> READY
WAITING_OUTPUT -> READY
```

If a CAS fails, the queue entry was stale and must be ignored.

## Actor Descriptor

Scheduling queues must not store heterogeneous actor objects. They store typed
references into the pipeline node tuple.

```mojo
struct ActorDescriptor(Copyable, Defaultable, ImplicitlyDestructible):
    var stage_idx: Int
    var replica_idx: Int
    var flat_id: Int

    def __init__(out self):
        self.stage_idx = -1
        self.replica_idx = -1
        self.flat_id = -1

    def __init__(out self, stage_idx: Int, replica_idx: Int, flat_id: Int):
        self.stage_idx = stage_idx
        self.replica_idx = replica_idx
        self.flat_id = flat_id
```

Meaning:

```text
stage_idx:
  index in the pipeline tuple

replica_idx:
  index inside nodes[stage_idx].actors

flat_id:
  index inside scheduler.actor_states
```

## Actor State

It is better to separate actor scheduling state from actor activation result,
even if the constants currently look similar.

```mojo
struct ActorState:
    comptime READY: UInt64 = 0
    comptime RUNNING: UInt64 = 1
    comptime WAITING_INPUT: UInt64 = 2
    comptime WAITING_OUTPUT: UInt64 = 3
    comptime DONE: UInt64 = 4
```

The activation result can stay close to your current `ActorStatus`:

```mojo
struct ActorResult:
    comptime READY: UInt64 = 0
    comptime BLOCKED_INPUT: UInt64 = 1
    comptime BLOCKED_OUTPUT: UInt64 = 2
    comptime DONE: UInt64 = 3
    comptime ERROR: UInt64 = 4
```

Allowed transitions:

```text
READY -> RUNNING
RUNNING -> READY
RUNNING -> WAITING_INPUT
RUNNING -> WAITING_OUTPUT
WAITING_INPUT -> READY
WAITING_OUTPUT -> READY
RUNNING -> DONE
```

Disallowed transitions:

```text
WAITING_INPUT -> RUNNING
WAITING_OUTPUT -> RUNNING
DONE -> READY
READY -> READY without state proof
RUNNING -> RUNNING
```

## Communicator Closure

The communicator should keep the queue API simple:

```text
push(msg)
try_push(msg)
pop()
try_pop()
```

It should not require `has_data()` or `has_capacity()`.

EOS can be synthesized from a closed communicator:

```mojo
struct Communicator[T: MessageTrait](Movable):
    var queue: UnsafePointer[MPMCQueue[MessageWrapper[Self.T]], MutExternalOrigin]
    var prodNum: Int
    var consNum: Int
    var destroyCount: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]
    var remainingProducers: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]
    var closed: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]
```

Constructor:

```mojo
def __init__(out self, pN: Int, cN: Int, queue_size: Int):
    self.queue = alloc[MPMCQueue[MessageWrapper[Self.T]]](1)
    self.queue.init_pointee_move(
        MPMCQueue[MessageWrapper[Self.T]](size=queue_size)
    )

    self.prodNum = pN
    self.consNum = cN

    self.destroyCount = alloc[Atomic[DType.int64]](1)
    self.destroyCount[] = Atomic[DType.int64](Int64(cN))

    self.remainingProducers = alloc[Atomic[DType.int64]](1)
    self.remainingProducers[] = Atomic[DType.int64](Int64(pN))

    self.closed = alloc[Atomic[DType.int64]](1)

    var initially_closed = Int64(0)
    if pN == 0:
        initially_closed = Int64(1)

    self.closed[] = Atomic[DType.int64](initially_closed)
```

The last producer closes only after its last successful push:

```mojo
def producer_finished(mut self) -> Bool:
    # Must be called after the producer completed its final push.
    var old_count = self.remainingProducers[].fetch_sub[
        ordering=Ordering.ACQUIRE_RELEASE
    ](1)

    if old_count == Int64(1):
        self.closed[].store[ordering=Ordering.RELEASE](Int64(1))
        return True

    return False
```

Closure check:

```mojo
def is_closed(mut self) -> Bool:
    return self.closed[].load[ordering=Ordering.ACQUIRE]() == Int64(1)
```

`try_pop()` must recheck after observing closure:

```mojo
def try_pop(mut self) -> Optional[MessageWrapper[Self.T]]:
    var maybe_msg = self.queue[].try_pop()
    if maybe_msg:
        return maybe_msg^

    if not self.is_closed():
        return None

    # Critical recheck after acquiring closed.
    maybe_msg = self.queue[].try_pop()
    if maybe_msg:
        return maybe_msg^

    return Optional(MessageWrapper[Self.T](eos=True))
```

Why the recheck is needed:

```text
The first try_pop may have happened before the final producer pushed.
After closed is acquired, the consumer must look again.
If the queue is still empty after that recheck, EOS is correct.
```

## Actor Fields

For cooperative scheduling, an actor needs both pending output and pending input.

```mojo
struct Actor[StageT: StageTrait](Copyable & ImplicitlyDestructible):
    var stage: Self.StageT
    var in_comm: UnsafePointer[Communicator[Self.StageT.InType], MutAnyOrigin]
    var out_comm: UnsafePointer[Communicator[Self.StageT.OutType], MutAnyOrigin]
    var pending_input: Optional[MessageWrapper[Self.StageT.InType]]
    var pending_output: Optional[MessageWrapper[Self.StageT.OutType]]
    var done: Bool
```

Constructor:

```mojo
def __init__(
    out self,
    stage: Self.StageT,
    in_comm: UnsafePointer[mut=True, Communicator[Self.StageT.InType], _],
    out_comm: UnsafePointer[mut=True, Communicator[Self.StageT.OutType], _],
):
    self.stage = stage.copy()
    self.in_comm = in_comm
    self.out_comm = out_comm
    self.pending_input = None
    self.pending_output = None
    self.done = False
```

The `pending_input` field exists because the parking recheck uses `try_pop()`.
If the recheck succeeds, the actor has already reserved a message. It must store
that message and consume it on the next activation.

The `pending_output` field exists because a failed `try_push()` returns the
undelivered message. The actor must retry it before consuming another input.

## Actor Helper Methods

These helpers make the scheduler simpler.

```mojo
def has_pending_input(self) -> Bool:
    return self.pending_input != None

def store_pending_input(mut self, var msg: MessageWrapper[Self.StageT.InType]):
    self.pending_input = Optional(msg^)

def take_or_try_pop_input(mut self) -> Optional[MessageWrapper[Self.StageT.InType]]:
    if self.pending_input:
        return Optional(self.pending_input.take())

    return self.in_comm[].try_pop()
```

Output helpers:

```mojo
def has_pending_output(self) -> Bool:
    return self.pending_output != None

def store_pending_output(mut self, var msg: MessageWrapper[Self.StageT.OutType]):
    self.pending_output = Optional(msg^)

def retry_pending_output(mut self) -> Bool:
    if not self.pending_output:
        return True

    var not_delivered = self.out_comm[].try_push(self.pending_output.take())
    if not_delivered:
        self.pending_output = not_delivered^
        return False

    return True
```

For scheduler parking, it is useful to expose typed methods:

```mojo
def try_reserve_input_for_parking(mut self) -> Bool:
    var maybe_msg = self.in_comm[].try_pop()
    if maybe_msg:
        self.pending_input = maybe_msg^
        return True

    return False

def try_flush_output_for_parking(mut self) -> Bool:
    if not self.pending_output:
        return True

    var not_delivered = self.out_comm[].try_push(self.pending_output.take())
    if not_delivered:
        self.pending_output = not_delivered^
        return False

    return True
```

## Actor Process Method

The activation method must be non-blocking. It must never call blocking
`pop()` or blocking `push()`.

Source actor:

```mojo
def process_source(mut self) raises -> UInt64:
    if self.done:
        return ActorResult.DONE

    if not self.retry_pending_output():
        return ActorResult.BLOCKED_OUTPUT

    var maybe_output = self.stage.next_element()
    if not maybe_output:
        self.done = True
        self.out_comm[].producer_finished()
        self.stage.received_eos()
        return ActorResult.DONE

    var msg = MessageWrapper[Self.StageT.OutType](
        data=rebind[Optional[Self.StageT.OutType]](maybe_output).take(),
        eos=False,
    )

    var not_delivered = self.out_comm[].try_push(msg)
    if not_delivered:
        self.pending_output = not_delivered^
        return ActorResult.BLOCKED_OUTPUT

    return ActorResult.READY
```

Transform actor:

```mojo
def process_transform(mut self) raises -> UInt64:
    if self.done:
        return ActorResult.DONE

    if not self.retry_pending_output():
        return ActorResult.BLOCKED_OUTPUT

    var maybe_input = self.take_or_try_pop_input()
    if not maybe_input:
        return ActorResult.BLOCKED_INPUT

    var input = maybe_input.take()
    if input.eos:
        self.done = True
        self.out_comm[].producer_finished()
        self.stage.received_eos()
        return ActorResult.DONE

    var maybe_output = self.stage.compute(
        rebind[MessageWrapper[Self.StageT.InType]](input).data.take()
    )

    if maybe_output:
        var output = MessageWrapper[Self.StageT.OutType](
            data=rebind[Optional[Self.StageT.OutType]](maybe_output).take(),
            eos=False,
        )

        var not_delivered = self.out_comm[].try_push(output)
        if not_delivered:
            self.pending_output = not_delivered^
            return ActorResult.BLOCKED_OUTPUT

    return ActorResult.READY
```

Sink actor:

```mojo
def process_sink(mut self) raises -> UInt64:
    if self.done:
        return ActorResult.DONE

    var maybe_input = self.take_or_try_pop_input()
    if not maybe_input:
        return ActorResult.BLOCKED_INPUT

    var input = maybe_input.take()
    if input.eos:
        self.done = True
        self.stage.received_eos()
        return ActorResult.DONE

    self.stage.consume_element(
        rebind[MessageWrapper[Self.StageT.InType]](input).data.take()
    )

    return ActorResult.READY
```

Main dispatcher inside `Actor.process()`:

```mojo
def process(mut self) raises -> UInt64:
    comptime if Self.StageT.kind == StageKind.SOURCE:
        return self.process_source()
    elif Self.StageT.kind == StageKind.TRANSFORM:
        return self.process_transform()
    elif Self.StageT.kind == StageKind.SINK:
        return self.process_sink()
    else:
        raise String("Invalid stage kind")
```

For `TRANSFORM_MANY`, the emitter also needs non-blocking behavior. A simple
first prototype can postpone `TRANSFORM_MANY` or require an emitter that stores
pending outputs.

## Scheduler Fields

The scheduler should not contain:

```mojo
var nodes: Tuple[*Self.Ts]
```

That causes tuple-copy ownership/evidence problems and duplicates actor storage.
Instead:

```mojo
struct Scheduler[*Ts: NodeTrait](ImplicitlyDestructible):
    var num_stages: Int
    var total_actors: Int
    var ready_queue: UnsafePointer[MPMCQueue[ActorDescriptor], MutExternalOrigin]
    var wq_inputs: UnsafePointer[MPMCQueue[ActorDescriptor], MutExternalOrigin]
    var wq_outputs: UnsafePointer[MPMCQueue[ActorDescriptor], MutExternalOrigin]
    var actor_states: UnsafePointer[Atomic[DType.uint64], MutExternalOrigin]
    var done_count: Atomic[DType.uint64]
```

The wait queues can be indexed by communicator:

```text
input wait queue for stage i:
  wq_inputs[i - 1]
  because stage i consumes from communicator i - 1

output wait queue for stage i:
  wq_outputs[i]
  because stage i produces to communicator i
```

For a pipeline with `N` stages, there are usually `N` output communicators in
the current construction style because a dummy input communicator exists for the
source. In a cleaned design, there are `N - 1` real stage-to-stage
communicators.

## Scheduler Constructor

The constructor borrows nodes only to count actors and seed the ready queue.

```mojo
def __init__(out self, mut nodes: Tuple[*Self.Ts]):
    self.num_stages = len(Self.Ts)
    self.total_actors = 0

    comptime for i in range(len(Self.Ts)):
        self.total_actors += nodes[i].parallelism()

    self.ready_queue = alloc[MPMCQueue[ActorDescriptor]](1)
    self.ready_queue.init_pointee_move(MPMCQueue[ActorDescriptor]())

    var flat_id = 0
    comptime for i in range(len(Self.Ts)):
        var par_degree = nodes[i].parallelism()
        for j in range(par_degree):
            self.ready_queue[].push(
                ActorDescriptor(stage_idx=i, replica_idx=j, flat_id=flat_id)
            )
            flat_id += 1

    self.wq_inputs = alloc[MPMCQueue[ActorDescriptor]](self.num_stages)
    self.wq_outputs = alloc[MPMCQueue[ActorDescriptor]](self.num_stages)

    for i in range(self.num_stages):
        (self.wq_inputs + i).init_pointee_move(MPMCQueue[ActorDescriptor]())
        (self.wq_outputs + i).init_pointee_move(MPMCQueue[ActorDescriptor]())

    self.actor_states = alloc[Atomic[DType.uint64]](self.total_actors)
    for i in range(self.total_actors):
        (self.actor_states + i)[] = Atomic[DType.uint64](ActorState.READY)

    self.done_count = Atomic[DType.uint64](0)
```

Destructor:

```mojo
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
```

## Scheduler Start

For a first prototype, one scheduler worker is enough.

```mojo
def start(mut self, mut nodes: Tuple[*Self.Ts]) raises:
    self.worker_loop(nodes)
```

Later, `start()` can create a fixed number of scheduler workers. Each worker
will run the same `worker_loop()`.

## State Transition Methods

Try to start:

```mojo
def try_start_actor(mut self, actor: ActorDescriptor) -> Bool:
    return self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.ACQUIRE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.READY, ActorState.RUNNING)
```

Mark ready:

```mojo
def mark_ready(mut self, actor: ActorDescriptor):
    if self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.READY):
        self.ready_queue[].push(actor)
```

Mark done:

```mojo
def mark_done(mut self, actor: ActorDescriptor):
    if self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.DONE):
        _ = self.done_count.fetch_add[ordering=Ordering.ACQUIRE_RELEASE](1)
```

## Typed Actor Dispatch

`ActorDescriptor` gives only indexes. The actual actor object is found by
compile-time dispatch over the heterogeneous node tuple.

```mojo
def process_actor(mut self, mut nodes: Tuple[*Self.Ts], actor: ActorDescriptor) raises -> UInt64:
    comptime for i in range(len(Self.Ts)):
        if actor.stage_idx == i:
            return nodes[i].actors[actor.replica_idx].process()

    return ActorResult.ERROR
```

Typed helper for storing pending input:

```mojo
def try_reserve_input_for_actor(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
) raises -> Bool:
    comptime for i in range(len(Self.Ts)):
        if actor.stage_idx == i:
            return nodes[i].actors[actor.replica_idx].try_reserve_input_for_parking()

    return False
```

Typed helper for retrying pending output:

```mojo
def try_flush_output_for_actor(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
) raises -> Bool:
    comptime for i in range(len(Self.Ts)):
        if actor.stage_idx == i:
            return nodes[i].actors[actor.replica_idx].try_flush_output_for_parking()

    return False
```

Typed helper for checking whether the input communicator is closed can dispatch
through the actor:

```mojo
def actor_input_is_closed(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
) -> Bool:
    comptime for i in range(len(Self.Ts)):
        if actor.stage_idx == i:
            return nodes[i].actors[actor.replica_idx].in_comm[].is_closed()

    return True
```

Typed helper for checking whether the output communicator is closed:

```mojo
def actor_output_is_closed(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
) -> Bool:
    comptime for i in range(len(Self.Ts)):
        if actor.stage_idx == i:
            return nodes[i].actors[actor.replica_idx].out_comm[].is_closed()

    return True
```

## Wait Queue Indexing

Given the current linear pipeline:

```mojo
def input_wait_queue_idx(self, actor: ActorDescriptor) -> Int:
    return actor.stage_idx - 1

def output_wait_queue_idx(self, actor: ActorDescriptor) -> Int:
    return actor.stage_idx
```

The source stage has no real input wait queue. It should never return
`BLOCKED_INPUT`.

The sink stage has no real output wait queue. It should never return
`BLOCKED_OUTPUT`.

## Wakeup Methods

Wake one input waiter. Keep skipping stale entries.

```mojo
def wake_one_input_waiter(mut self, comm_idx: Int):
    while True:
        var maybe_actor = self.wq_inputs[comm_idx].try_pop()
        if not maybe_actor:
            return

        var actor = maybe_actor.take()

        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready_queue[].push(actor)
            return
```

Wake all input waiters. This is needed when a communicator closes.

```mojo
def wake_all_input_waiters(mut self, comm_idx: Int):
    while True:
        var maybe_actor = self.wq_inputs[comm_idx].try_pop()
        if not maybe_actor:
            return

        var actor = maybe_actor.take()

        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready_queue[].push(actor)
```

Wake one output waiter after a consumer successfully pops.

```mojo
def wake_one_output_waiter(mut self, comm_idx: Int):
    while True:
        var maybe_actor = self.wq_outputs[comm_idx].try_pop()
        if not maybe_actor:
            return

        var actor = maybe_actor.take()

        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_OUTPUT, ActorState.READY):
            self.ready_queue[].push(actor)
            return
```

## Input Parking

This method is called after an actor returns `BLOCKED_INPUT`. The actor is still
logically `RUNNING`.

The sequence is:

```text
RUNNING -> WAITING_INPUT
push actor into input wait queue
recheck input by try_pop()
if data was found, store it as pending_input and make actor READY
if communicator closed, make actor READY so it can receive synthesized EOS
```

Mojo-like method:

```mojo
def park_on_input_or_ready(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
) raises:
    if actor.stage_idx == 0:
        self.mark_ready(actor)
        return

    var comm_idx = self.input_wait_queue_idx(actor)

    if not self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.WAITING_INPUT):
        return

    self.wq_inputs[comm_idx].push(actor)

    # Recheck after publishing the wait entry.
    if self.try_reserve_input_for_actor(nodes, actor):
        self.wake_one_output_waiter(comm_idx)

        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready_queue[].push(actor)

        return

    # If the communicator is closed, wake the actor so its next process() call
    # can call try_pop() and receive synthesized EOS.
    if self.actor_input_is_closed(nodes, actor):
        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready_queue[].push(actor)
```

Why this prevents lost input wakeups:

```text
If a producer pushes before the actor is visible in the wait queue,
the recheck can reserve the message.

If a producer pushes after the actor is visible in the wait queue,
the producer-side wakeup can move it to READY.
```

## Output Parking

This method is called after an actor returns `BLOCKED_OUTPUT`. The actor is
still logically `RUNNING`, and it already owns an undelivered message in
`pending_output`.

The sequence is:

```text
RUNNING -> WAITING_OUTPUT
push actor into output wait queue
recheck output by retrying try_push(pending_output)
if push succeeds, wake input waiter and make actor READY
```

Mojo-like method:

```mojo
def park_on_output_or_ready(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
) raises:
    var comm_idx = self.output_wait_queue_idx(actor)

    if not self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.WAITING_OUTPUT):
        return

    self.wq_outputs[comm_idx].push(actor)

    # Recheck after publishing the wait entry.
    if self.try_flush_output_for_actor(nodes, actor):
        self.wake_one_input_waiter(comm_idx)

        if self.actor_states[actor.flat_id].compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_OUTPUT, ActorState.READY):
            self.ready_queue[].push(actor)
```

Why this prevents lost output wakeups:

```text
If a consumer frees capacity before the actor is visible in the wait queue,
the recheck can use that capacity.

If a consumer frees capacity after the actor is visible in the wait queue,
the consumer-side wakeup can move it to READY.
```

## Progress Notification Methods

If `Actor.process()` calls `in_comm[].try_pop()` and `out_comm[].try_push()`
directly, the scheduler still needs to notify waiters after an activation that
made progress.

The notification can be conservative. It is safe to wake an output waiter on the
input communicator and an input waiter on the output communicator after a
successful activation. Some wakeups may be spurious, but the actor-state CAS
will prevent duplicate execution.

For an actor that returned `READY`:

```mojo
def notify_after_ready_activation(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
):
    # If the actor consumed input, capacity may have been freed upstream.
    if actor.stage_idx > 0:
        self.wake_one_output_waiter(self.input_wait_queue_idx(actor))

    # If the actor produced output, data may be available downstream.
    if actor.stage_idx < self.num_stages - 1:
        self.wake_one_input_waiter(self.output_wait_queue_idx(actor))
```

For an actor that returned `BLOCKED_INPUT`:

```mojo
def notify_after_blocked_input(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
):
    # A transform may have flushed pending_output, then found no new input.
    # Wake downstream input waiters conservatively.
    if actor.stage_idx < self.num_stages - 1:
        self.wake_one_input_waiter(self.output_wait_queue_idx(actor))
```

For an actor that returned `BLOCKED_OUTPUT`:

```mojo
def notify_after_blocked_output(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
):
    # A transform may have consumed input, then failed to push output.
    # Wake upstream output waiters conservatively.
    if actor.stage_idx > 0:
        self.wake_one_output_waiter(self.input_wait_queue_idx(actor))
```

For an actor that returned `DONE`:

```mojo
def notify_after_done(
    mut self,
    mut nodes: Tuple[*Self.Ts],
    actor: ActorDescriptor,
):
    # A DONE transform/sink may have consumed input or observed EOS. Waking an
    # upstream producer is harmless and can release capacity waiters.
    if actor.stage_idx > 0:
        self.wake_one_output_waiter(self.input_wait_queue_idx(actor))

    # A DONE source/transform may have closed its output communicator. If it is
    # closed, all downstream input waiters must be woken so they can observe EOS.
    if actor.stage_idx < self.num_stages - 1:
        if self.actor_output_is_closed(nodes, actor):
            self.wake_all_input_waiters(self.output_wait_queue_idx(actor))
```

Parking rechecks must also notify:

```text
input parking recheck succeeds with try_pop():
  wake one output waiter

output parking recheck succeeds with try_push():
  wake one input waiter
```

An alternative later design is to centralize every pop and push in
scheduler-aware methods:

```mojo
def try_push_and_wake[
    T: MessageTrait
](
    mut self,
    comm_idx: Int,
    var msg: MessageWrapper[T],
    mut comm: UnsafePointer[Communicator[T], MutAnyOrigin],
) -> Optional[MessageWrapper[T]]:
    var not_delivered = comm[].try_push(msg^)
    if not_delivered:
        return not_delivered^

    self.wake_one_input_waiter(comm_idx)
    return None
```

When a consumer successfully pops input, the scheduler should wake one output
waiter on that communicator:

```mojo
def try_pop_and_wake[
    T: MessageTrait
](
    mut self,
    comm_idx: Int,
    mut comm: UnsafePointer[Communicator[T], MutAnyOrigin],
) -> Optional[MessageWrapper[T]]:
    var maybe_msg = comm[].try_pop()
    if maybe_msg:
        var msg = maybe_msg.take()
        if not msg.eos:
            self.wake_one_output_waiter(comm_idx)
        return Optional(msg^)

    return None
```

In that later version, `Actor.process()` would not call communicator operations
directly. For the first prototype, the `notify_after_*()` methods are the
simpler path.

## Worker Loop

The worker loop treats ready queue entries as hints.

```mojo
def worker_loop(mut self, mut nodes: Tuple[*Self.Ts]) raises:
    while self.done_count.load[ordering=Ordering.ACQUIRE]() < UInt64(self.total_actors):
        var maybe_actor = self.ready_queue[].try_pop()
        if not maybe_actor:
            continue

        var actor = maybe_actor.take()

        if not self.try_start_actor(actor):
            continue

        var result = self.process_actor(nodes, actor)

        if result == ActorResult.READY:
            self.notify_after_ready_activation(nodes, actor)
            self.mark_ready(actor)

        elif result == ActorResult.BLOCKED_INPUT:
            self.notify_after_blocked_input(nodes, actor)
            self.park_on_input_or_ready(nodes, actor)

        elif result == ActorResult.BLOCKED_OUTPUT:
            self.notify_after_blocked_output(nodes, actor)
            self.park_on_output_or_ready(nodes, actor)

        elif result == ActorResult.DONE:
            self.notify_after_done(nodes, actor)
            self.mark_done(actor)

        else:
            self.mark_done(actor)
```

For multiple scheduler workers, the same loop can run on several runtime
threads because actor ownership is protected by `READY -> RUNNING`.

## Pipeline Construction

The pipeline should create actors first, then construct the scheduler with a
borrow of `self.nodes`.

```mojo
def run_cooperative(mut self) raises:
    var first_comm = alloc[Communicator[Self.Ts[0].StageT.InType]](1)
    first_comm.init_pointee_move(
        Communicator[Self.Ts[0].StageT.InType](
            pN=0,
            cN=self.nodes[0].parallelism(),
            queue_size=self.queue_size,
        )
    )

    self._run_cooperative_from[0, Self.N](first_comm)

    var scheduler = Scheduler[*Self.Ts](self.nodes)
    scheduler.start(self.nodes)
```

Recursive actor construction:

```mojo
def _run_cooperative_from[
    idx: Int,
    length: Int,
    M: MessageTrait,
](
    mut self,
    in_comm: UnsafePointer[mut=True, Communicator[M], _],
):
    var np = self.nodes[idx].parallelism()
    var nc = 0

    comptime if idx < Self.N - 1:
        nc = self.nodes[idx + 1].parallelism()

    var out_comm = alloc[Communicator[Self.Ts[idx].StageT.OutType]](1)
    out_comm.init_pointee_move(
        Communicator[Self.Ts[idx].StageT.OutType](
            pN=np,
            cN=nc,
            queue_size=self.queue_size,
        )
    )

    var typed_in_comm = rebind[
        UnsafePointer[Communicator[Self.Ts[idx].StageT.InType], MutAnyOrigin]
    ](in_comm)

    for _ in range(np):
        self.nodes[idx].add_actor(
            Actor[Self.Ts[idx].StageT](
                stage=self.nodes[idx].make_stage(),
                in_comm=typed_in_comm,
                out_comm=out_comm,
            )
        )

    comptime if idx + 1 < Self.N:
        self._run_cooperative_from[
            idx + 1,
            length,
            Self.Ts[idx].StageT.OutType,
        ](out_comm)
```

This is intentionally a borrow-based design:

```text
Pipeline owns nodes.
Nodes own actors.
Scheduler owns scheduling metadata.
Scheduler borrows nodes while running.
```

## Memory Ordering

Use `Ordering.SEQUENTIAL` first if debugging difficult races. After the logic is
correct, the intended acquire/release protocol is:

```text
READY -> RUNNING:
  ACQUIRE
  The worker takes ownership and sees the actor fields published by the last
  worker.

RUNNING -> READY:
  RELEASE
  Publishes actor field updates before another worker runs it.

RUNNING -> WAITING_INPUT / WAITING_OUTPUT:
  RELEASE
  Publishes the wait state before queue wakeups can observe it.

WAITING_INPUT / WAITING_OUTPUT -> READY:
  RELEASE
  Publishes that the actor is ready before pushing to ready_queue.

RUNNING -> DONE:
  RELEASE
  Publishes final actor state.
```

Failure ordering can be `RELAXED` when failure means "ignore this stale entry"
and the code does not read actor fields based on the failed CAS.

The MPMC queues must be linearizable independently. Actor-state atomics do not
fix an incorrect queue implementation.

## Deadlock Checklist

A linear MoStream pipeline should not deadlock if all of these hold:

```text
All activations are non-blocking.
Every actor is run only after READY -> RUNNING succeeds.
Every wait queue wake skips stale entries.
Input parking rechecks with try_pop().
Output parking rechecks with try_push(pending_output).
Successful pushes, or post-activation notifications, wake input waiters.
Successful pops, or post-activation notifications, wake output waiters.
Closing a communicator wakes all input waiters.
EOS is synthesized from closed + empty, not pushed into a bounded queue.
```

Common implementation bugs:

```text
Actor is both READY and WAITING because state was not authoritative.
Actor runs twice because ready entries were not CAS-checked.
Consumer sleeps forever because it did not recheck after entering wait queue.
Producer sleeps forever because it did not recheck after entering wait queue.
Stale waiter consumes the only wake attempt.
EOS message cannot be pushed because the bounded queue is full.
Scheduler copied nodes instead of borrowing them.
```

## Recommended Implementation Order

1. Keep the standard MoStream runtime unchanged.
2. Finish communicator closure with `remainingProducers` and `closed`.
3. Add `pending_input` to `Actor`.
4. Make `Actor.process()` fully non-blocking.
5. Build actors into `Pipeline.nodes`.
6. Create `Scheduler` without storing or copying `nodes`.
7. Implement single-worker `worker_loop()`.
8. Implement input parking with `try_pop()` recheck.
9. Implement output parking with `try_push()` recheck.
10. Add wakeups after successful push/pop.
11. Add multi-worker scheduling only after the single-worker version is correct.
