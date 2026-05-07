# Cooperative Scheduling Prototype

This document sketches the concrete MoStream changes needed to support more
logical stage replicas than runtime worker threads.

The important design point is that a stage replica must stop before it spins.
It should try one input/output operation, report why it cannot continue, and let
a small scheduler run another ready replica.

## New Non-Blocking Queue Operations

`MPMCQueue.try_push()` and `Communicator.try_pop()/try_push()` are the first
mechanical step. They allow the cooperative backend to avoid the current
blocking behavior in `Communicator.pop()` and `Communicator.push()`.

`try_push()` must not consume the message when it returns `False`. Its argument
therefore uses Mojo's default immutable borrowed convention, and the queue copies
the value only after it has claimed a slot.

## Step Result

```mojo
struct StepResult:
    comptime READY: Int = 0
    comptime BLOCKED_INPUT: Int = 1
    comptime BLOCKED_OUTPUT: Int = 2
    comptime DONE: Int = 3
```

## Typed Transform Actor

Each stage replica becomes a typed actor. The scheduler can only run an actor
through `step()`, and `step()` processes at most one stream element.

```mojo
from std.collections import Optional
from MoStream.communicator import Communicator, MessageTrait, MessageWrapper
from MoStream.stage import StageTrait

struct TransformActor[
    Stage: StageTrait,
    In: MessageTrait,
    Out: MessageTrait,
]:
    var stage: Stage
    var in_comm: UnsafePointer[mut=True, Communicator[In], _]
    var out_comm: UnsafePointer[mut=True, Communicator[Out], _]
    var pending_output: Optional[MessageWrapper[Out]]
    var done: Bool

    def __init__(
        out self,
        stage: Stage,
        in_comm: UnsafePointer[mut=True, Communicator[In], _],
        out_comm: UnsafePointer[mut=True, Communicator[Out], _],
    ):
        self.stage = stage
        self.in_comm = in_comm
        self.out_comm = out_comm
        self.pending_output = None
        self.done = False

    def step(mut self) raises -> Int:
        if self.done:
            return StepResult.DONE

        if self.pending_output:
            var pending = self.pending_output.take()
            if not self.out_comm[].try_push(pending):
                self.pending_output = Optional(pending^)
                return StepResult.BLOCKED_OUTPUT

        var maybe_input = self.in_comm[].try_pop()
        if not maybe_input:
            return StepResult.BLOCKED_INPUT

        var input = maybe_input.take()
        if input.eos:
            self.done = True
            self.out_comm[].producer_finished()
            self.stage.received_eos()
            return StepResult.DONE

        var output = self.stage.compute(
            rebind[MessageWrapper[Stage.InType]](input).data.take()
        )
        if output:
            var msg = MessageWrapper[Out](
                data=rebind[Optional[Out]](output).take(),
                eos=False,
            )
            if not self.out_comm[].try_push(msg):
                self.pending_output = Optional(msg^)
                return StepResult.BLOCKED_OUTPUT

        return StepResult.READY
```

## Typed Source Actor

The source actor has no input dependency. It blocks only when its output queue is
full.

```mojo
struct SourceActor[
    Stage: StageTrait,
    Out: MessageTrait,
]:
    var stage: Stage
    var out_comm: UnsafePointer[mut=True, Communicator[Out], _]
    var pending_output: Optional[MessageWrapper[Out]]
    var done: Bool

    def step(mut self) raises -> Int:
        if self.done:
            return StepResult.DONE

        if self.pending_output:
            var pending = self.pending_output.take()
            if not self.out_comm[].try_push(pending):
                self.pending_output = Optional(pending^)
                return StepResult.BLOCKED_OUTPUT

        var output = self.stage.next_element()
        if output == None:
            self.done = True
            self.out_comm[].producer_finished()
            self.stage.received_eos()
            return StepResult.DONE

        var msg = MessageWrapper[Out](
            data=rebind[Optional[Out]](output).take(),
            eos=False,
        )
        if not self.out_comm[].try_push(msg):
            self.pending_output = Optional(msg^)
            return StepResult.BLOCKED_OUTPUT

        return StepResult.READY
```

## Typed Sink Actor

The sink actor blocks only when its input queue is empty.

```mojo
struct SinkActor[
    Stage: StageTrait,
    In: MessageTrait,
]:
    var stage: Stage
    var in_comm: UnsafePointer[mut=True, Communicator[In], _]
    var done: Bool

    def step(mut self) raises -> Int:
        if self.done:
            return StepResult.DONE

        var maybe_input = self.in_comm[].try_pop()
        if not maybe_input:
            return StepResult.BLOCKED_INPUT

        var input = maybe_input.take()
        if input.eos:
            self.done = True
            self.stage.received_eos()
            return StepResult.DONE

        self.stage.consume_element(
            rebind[MessageWrapper[Stage.InType]](input).data.take()
        )
        return StepResult.READY
```

## Scheduler Responsibilities

The scheduler owns readiness. A blocked actor never resumes itself.

```mojo
struct WaitQueue:
    # Prototype abstraction. A single-threaded scheduler can implement this with
    # List[Int]. A multi-worker scheduler needs synchronization or a lock-free
    # queue plus actor-state CAS to avoid duplicate wakeups.
    def push(mut self, actor_id: Int):
        ...

    def try_pop(mut self) -> Optional[Int]:
        ...

struct Scheduler:
    var ready_actor_ids: MPMCQueue[Int]
    var done_count: Atomic[DType.int64]
    var actor_count: Int

    # One wait list per communicator.
    var input_waiters: List[WaitQueue]
    var output_waiters: List[WaitQueue]

    def mark_waiting_on_input(mut self, actor_id: Int, comm_id: Int):
        self.input_waiters[comm_id].push(actor_id)

    def mark_waiting_on_output(mut self, actor_id: Int, comm_id: Int):
        self.output_waiters[comm_id].push(actor_id)

    def wake_one_input_waiter(mut self, comm_id: Int):
        var maybe_actor_id = self.input_waiters[comm_id].try_pop()
        if maybe_actor_id:
            _ = self.ready_actor_ids.push(maybe_actor_id.take())

    def wake_all_input_waiters(mut self, comm_id: Int):
        while True:
            var maybe_actor_id = self.input_waiters[comm_id].try_pop()
            if not maybe_actor_id:
                return
            _ = self.ready_actor_ids.push(maybe_actor_id.take())

    def wake_one_output_waiter(mut self, comm_id: Int):
        var maybe_actor_id = self.output_waiters[comm_id].try_pop()
        if maybe_actor_id:
            _ = self.ready_actor_ids.push(maybe_actor_id.take())
```

The important invariant is:

```text
an actor is in exactly one place:
ready queue, running on one worker, one wait queue, or done
```

For the multi-worker backend this should be enforced with an atomic actor state,
not by trusting plain lists.

The producer side wakes input waiters after a successful push:

```mojo
if self.out_comm[].try_push(msg):
    scheduler.wake_one_input_waiter(out_comm_id)
    return StepResult.READY
```

The consumer side wakes output waiters after a successful pop:

```mojo
var maybe_input = self.in_comm[].try_pop()
if maybe_input:
    scheduler.wake_one_output_waiter(in_comm_id)
```

End-of-stream should wake all input waiters:

```mojo
if last_producer_finished:
    scheduler.wake_all_input_waiters(out_comm_id)
```

## Worker Loop

There are only `parallelism_level()` scheduler workers, even when there are many
more logical actors.

```mojo
async
def scheduler_worker(mut scheduler: Scheduler):
    while True:
        var maybe_actor_id = scheduler.ready_actor_ids.pop()
        if not maybe_actor_id:
            if scheduler.done_count.load() == scheduler.actor_count:
                return
            continue

        var actor_id = maybe_actor_id.take()
        var result = scheduler.step_actor(actor_id)

        if result == StepResult.READY:
            _ = scheduler.ready_actor_ids.push(actor_id)
        elif result == StepResult.BLOCKED_INPUT:
            scheduler.mark_waiting_on_input(actor_id, scheduler.actor_input_comm(actor_id))
        elif result == StepResult.BLOCKED_OUTPUT:
            scheduler.mark_waiting_on_output(actor_id, scheduler.actor_output_comm(actor_id))
        elif result == StepResult.DONE:
            _ = scheduler.done_count.fetch_add(1)
```

## Pipeline Integration Shape

The current backend creates one Mojo task per stage replica. The cooperative
backend should create one actor per stage replica, then create only a bounded
number of scheduler workers.

```mojo
def run_cooperative(mut self):
    var scheduler = Scheduler()

    comptime for idx in range(0, Self.N):
        for replica in range(0, self.nodes[idx].parallelism()):
            scheduler.add_actor(self.make_actor[idx](replica))

    var workers = parallelism_level()
    for _ in range(0, workers):
        self.tg.create_task(scheduler_worker(scheduler))

    self.tg.wait()
```

## Lost Wakeup Rule

Parking must be atomic with respect to the condition being tested. The scheduler
should expose one operation that registers a waiter and then rechecks the
communicator before the actor is fully parked:

```mojo
def park_on_input_or_ready(mut self, actor_id: Int, comm_id: Int):
    self.input_waiters[comm_id].push(actor_id)
    if self.communicator_has_data_or_eos(comm_id):
        self.remove_input_waiter(actor_id, comm_id)
        _ = self.ready_actor_ids.push(actor_id)
```

This avoids:

```text
consumer sees empty
producer pushes and wakes nobody
consumer parks forever
```

## Integration Notes

The largest implementation question is not the actor logic. It is how to store
heterogeneous typed actors in one scheduler. The choices are:

1. A compile-time generated scheduler that keeps typed actor lists per pipeline
   stage.
2. A manual type-erased actor wrapper with typed function pointers for `step`,
   input communicator id, and output communicator id.
3. A first implementation of `run_cooperative_single_worker()` that uses
   compile-time recursion and validates the protocol before adding parallel
   scheduler workers.

The safest path is option 3, then option 1.

A plain `List[List[Int]]` is acceptable only for option 3 if the whole scheduler
is single-threaded and exclusively owns all wait-queue mutations. Once multiple
scheduler workers can park and wake actors concurrently, each per-communicator
wait queue must be synchronized, and wakeups must transition actor state
atomically before pushing the actor back to `ready_actor_ids`.
