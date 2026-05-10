# Cooperative Scheduler Correctness Design

This note describes a cooperative scheduling design for MoStream that allows
more logical actors than runtime worker threads while avoiding the main races
we discussed: lost wakeups, duplicate scheduling, output-side deadlock, and EOS
deadlock.

It is intentionally a design note, not a direct patch to the current code. Code
blocks are Mojo-like pseudo-code and may need small syntax adjustments when
ported into the library.

## Goal

The current MoStream execution model creates one long-lived async task per stage
replica. Each replica spins in blocking `pop()` or `push()` operations, so it
effectively occupies one runtime worker forever.

The cooperative model should instead create:

```text
many logical actors
few scheduler workers
```

Each actor runs only one activation at a time. When it cannot make progress, it
parks itself through the scheduler and another actor can run.

## Core Ownership Model

The scheduler should not copy `Pipeline.nodes`.

Prefer this separation:

```text
Pipeline:
  owns the pipeline description: nodes, stages, parallelism

CooperativeRuntime / Scheduler:
  owns runtime state: actors, actor states, ready queue, wait queues
```

During runtime construction, the pipeline can lend its node tuple to a builder
method:

```mojo
var scheduler = Scheduler[*Self.Ts]()
scheduler.build_from_nodes(self.nodes)
scheduler.run()
```

The scheduler does not need to store a copy of the node tuple. If it only needs
nodes during construction, borrow them as method arguments and then store actor
runtime state separately.

## Actor Identity

Do not put heterogeneous actor objects directly into one queue. Store actor
references in scheduling queues.

```mojo
struct ActorRef(Copyable, Defaultable):
    var stage_idx: Int
    var replica_idx: Int
    var flat_id: Int
```

The `stage_idx` chooses the typed stage runtime. The `replica_idx` chooses the
actor inside that homogeneous stage runtime. The `flat_id` indexes the global
actor-state array.

The ready queue and communicator wait queues store only `ActorRef`.

## Actor States

Every actor has an atomic state.

```mojo
struct ActorState:
    comptime READY: Int64 = 0
    comptime RUNNING: Int64 = 1
    comptime WAITING_INPUT: Int64 = 2
    comptime WAITING_OUTPUT: Int64 = 3
    comptime DONE: Int64 = 4
```

The key invariant:

```text
An actor is logically in exactly one place:

READY          in the ready queue, or represented by a stale ready entry
RUNNING        owned by exactly one scheduler worker
WAITING_INPUT  eligible to be woken by an input communicator
WAITING_OUTPUT eligible to be woken by an output communicator
DONE           never runnable again
```

Queues may contain stale entries. The atomic actor state is the source of truth.

This is critical. A wait queue entry does not mean the actor is still waiting.
A ready queue entry does not mean the actor can run. The scheduler must verify
the state with CAS before running or waking an actor.

## Legal State Transitions

```text
READY -> RUNNING
  A scheduler worker starts an actor.

RUNNING -> READY
  The actor made progress and can run again later.

RUNNING -> WAITING_INPUT
  The actor tried to pop, found no input, and was parked as a consumer.

RUNNING -> WAITING_OUTPUT
  The actor tried to push, found no capacity, and was parked as a producer.

WAITING_INPUT -> READY
  A producer pushed data or closed the input communicator.

WAITING_OUTPUT -> READY
  A consumer popped data and freed capacity.

RUNNING -> DONE
  The actor reached EOS or finished.
```

There should be no direct:

```text
WAITING_INPUT -> RUNNING
WAITING_OUTPUT -> RUNNING
RUNNING -> RUNNING
DONE -> READY
```

## Scheduler Worker Loop

The worker loop must treat ready queue entries as hints.

```mojo
def try_start_actor(mut self, actor: ActorRef) -> Bool:
    return self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.ACQUIRE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.READY, ActorState.RUNNING)
```

Then:

```mojo
def worker_step(mut self):
    var maybe_actor = self.ready.try_pop()
    if not maybe_actor:
        return

    var actor = maybe_actor.take()

    if not self.try_start_actor(actor):
        # Stale ready entry. Another worker already owns this actor, or it is
        # waiting/done.
        return

    var result = self.process_actor(actor)

    if result == ActorStatus.READY:
        self.finish_ready(actor)
    elif result == ActorStatus.BLOCKED_INPUT:
        self.park_on_input_or_ready(actor, self.actor_input_comm(actor))
    elif result == ActorStatus.BLOCKED_OUTPUT:
        self.park_on_output_or_ready(actor, self.actor_output_comm(actor))
    elif result == ActorStatus.DONE:
        self.finish_done(actor)
```

Finishing ready:

```mojo
def finish_ready(mut self, actor: ActorRef):
    if self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.READY):
        self.ready.push(actor)
```

Finishing done:

```mojo
def finish_done(mut self, actor: ActorRef):
    if self.actor_states[actor.flat_id].compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.DONE):
        _ = self.done_count.fetch_add(1)
```

## Communicator Responsibilities

The MPMC queue should stay low-level:

```text
try_pop() -> Optional[MessageWrapper[T]]
try_push(msg) -> Optional[MessageWrapper[T]]
```

The cooperative communicator owns scheduling-level information:

```mojo
struct CooperativeCommunicator[T: MessageTrait]:
    var queue: MPMCQueue[MessageWrapper[T]]
    var input_waiters: WaitQueue[ActorRef]
    var output_waiters: WaitQueue[ActorRef]
    var closed: Atomic[DType.bool]
    var finished_producers: Atomic[DType.int64]
```

The MPMC queue does not know about actors. The communicator/scheduler boundary
handles wakeups.

This design does not require adding `has_data()` or `has_capacity()` to
`MPMCQueue`. Rechecks can be implemented with the existing non-blocking
operations:

```text
input recheck:
  use try_pop()
  if it succeeds, store the popped message as actor.pending_input

output recheck:
  use try_push(actor.pending_output)
  if it succeeds, clear pending_output and wake one input waiter
```

That is slightly more work than a pure predicate, but it fits the current queue
API and gives a stronger result: the actor actually reserves the message or
output slot during the recheck.

## Lost Wakeup Problem

The dangerous consumer-side interleaving is:

```text
A: try_pop() -> empty
B: try_push(item) -> success
B: checks input_waiters -> empty
B: wakes nobody
A: appends itself to input_waiters
A: sleeps forever
```

Now the queue contains data, but A is asleep.

The output side has the symmetric problem:

```text
P: try_push(pending_output) -> full
C: try_pop() -> success
C: checks output_waiters -> empty
C: wakes nobody
P: appends itself to output_waiters
P: sleeps forever
```

Now there is queue capacity, but P is asleep.

The fix is: parking must publish the actor as waiting, enqueue it as a waiter,
and then recheck the condition.

## Input Parking Primitive

This primitive is called after an actor returned `BLOCKED_INPUT`. The actor is
still in state `RUNNING`.

Because the current queue API has no `has_data_or_closed()` predicate, an input
parking recheck should use `try_pop()`. If the recheck succeeds, the actor must
store the popped message in `pending_input` before it becomes ready again.

This means actors that can block on input should have:

```mojo
var pending_input: Optional[MessageWrapper[Stage.InType]]
```

At the beginning of `process()`, a transform or sink actor should first consume
`pending_input` if it exists. Only if there is no pending input should it call
`try_pop()`.

```mojo
def park_on_input_or_ready(mut self, actor: ActorRef, comm_id: Int):
    var state = self.actor_states[actor.flat_id]

    if not state.compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.WAITING_INPUT):
        return

    self.communicators[comm_id].input_waiters.push(actor)

    # Recheck after the actor is visible in the wait queue.
    # There is no has_data() API, so try to pop now.
    var maybe_msg = self.communicators[comm_id].try_pop()

    if maybe_msg:
        self.store_pending_input(actor, maybe_msg.take())
        self.wake_one_output_waiter(comm_id)

        if state.compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready.push(actor)
        return

    if self.communicators[comm_id].is_closed():
        self.store_pending_input(
            actor,
            MessageWrapper[self.communicator_type[comm_id]](eos=True),
        )

        if state.compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready.push(actor)
```

Why this works:

```text
If a producer pushed before the actor entered input_waiters:
  the recheck can pop the data into pending_input and make the actor ready.

If a producer pushes after the actor entered input_waiters:
  the producer can wake the actor normally.

If another consumer takes an item before this actor's recheck:
  the recheck returns None and the actor remains waiting.

If this actor's recheck gets the item:
  the item is reserved in pending_input, so another consumer cannot take it.
```

With the current queue API, the input recheck is a reservation because it uses
`try_pop()`. This is fine, but it requires `pending_input`.

## Output Parking Primitive

This primitive is called after an actor returned `BLOCKED_OUTPUT`. The actor is
still in state `RUNNING`, and it must already have stored the failed output in
`pending_output`.

Because the current queue API has no `has_capacity()` predicate, an output
parking recheck should retry `try_push(pending_output)`. If the recheck
succeeds, clear `pending_output`, wake one input waiter, and make the actor
ready.

```mojo
def park_on_output_or_ready(mut self, actor: ActorRef, comm_id: Int):
    var state = self.actor_states[actor.flat_id]

    if not state.compare_exchange[
        success_ordering=Ordering.RELEASE,
        failure_ordering=Ordering.RELAXED,
    ](ActorState.RUNNING, ActorState.WAITING_OUTPUT):
        return

    self.communicators[comm_id].output_waiters.push(actor)

    # Recheck after the producer is visible in the wait queue.
    # There is no has_capacity() API, so retry the pending push now.
    var maybe_msg = self.take_pending_output(actor)
    if maybe_msg:
        var not_delivered = self.communicators[comm_id].try_push(maybe_msg.take())
        if not_delivered:
            self.store_pending_output(actor, not_delivered.take())
            return

        self.wake_one_input_waiter(comm_id)

        if state.compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_OUTPUT, ActorState.READY):
            self.ready.push(actor)
```

When this actor later runs after a normal wakeup, it must retry
`pending_output` before consuming a new input.

With the current queue API, this recheck is an actual push attempt, not a
capacity test.

## Wakeup Primitives

Wakeups must skip stale wait queue entries.

```mojo
def wake_one_input_waiter(mut self, comm_id: Int):
    while True:
        var maybe_actor = self.communicators[comm_id].input_waiters.try_pop()
        if not maybe_actor:
            return

        var actor = maybe_actor.take()
        var state = self.actor_states[actor.flat_id]

        if state.compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_INPUT, ActorState.READY):
            self.ready.push(actor)
            return

        # Stale entry. Keep looking.
```

The output-side version is symmetric:

```mojo
def wake_one_output_waiter(mut self, comm_id: Int):
    while True:
        var maybe_actor = self.communicators[comm_id].output_waiters.try_pop()
        if not maybe_actor:
            return

        var actor = maybe_actor.take()
        var state = self.actor_states[actor.flat_id]

        if state.compare_exchange[
            success_ordering=Ordering.RELEASE,
            failure_ordering=Ordering.RELAXED,
        ](ActorState.WAITING_OUTPUT, ActorState.READY):
            self.ready.push(actor)
            return

        # Stale entry. Keep looking.
```

This is why stale queue entries are safe. Only one CAS can move the actor back
to `READY`.

## Push And Pop Rules

When a producer successfully pushes, wake a consumer:

```mojo
def try_push_and_wake[T: MessageTrait](
    mut self,
    comm_id: Int,
    var msg: MessageWrapper[T],
) -> Optional[MessageWrapper[T]]:
    var not_delivered = self.communicators[comm_id].try_push(msg^)
    if not_delivered:
        return not_delivered^

    self.wake_one_input_waiter(comm_id)
    return None
```

When a consumer successfully pops, wake a producer:

```mojo
def try_pop_and_wake[T: MessageTrait](
    mut self,
    comm_id: Int,
) -> Optional[MessageWrapper[T]]:
    var maybe_msg = self.communicators[comm_id].try_pop()
    if maybe_msg:
        self.wake_one_output_waiter(comm_id)
        return maybe_msg

    if self.communicators[comm_id].is_closed():
        return Optional(MessageWrapper[T](eos=True))

    return None
```

Do not wake only one stale entry and stop. If a stale actor is popped, continue
until one actor is actually moved from waiting to ready or the wait queue is
empty.

## EOS Handling

Avoid implementing EOS only by pushing EOS messages into a bounded queue.

If EOS requires queue capacity, a full queue can make shutdown depend on future
consumer progress. That can interact badly with wakeup bugs.

Prefer this communicator state:

```text
finished_producers reaches zero
communicator.closed = true
wake all input waiters
```

Then:

```mojo
def producer_finished(mut self, comm_id: Int):
    var old = self.communicators[comm_id].finished_producers.fetch_sub(1)
    if old == 1:
        self.communicators[comm_id].closed.store(True)
        self.wake_all_input_waiters(comm_id)
```

And consumer pop uses:

```text
if queue has data:
  return data
if communicator is closed:
  return EOS
return None
```

This makes EOS independent of bounded queue capacity.

## Shared Queue Semantics

A communicator queue is shared by all replicas of the downstream stage. A wakeup
does not grant ownership of an item by itself.

If parking rechecks are implemented with predicate-style `has_data()` in the
future, this is allowed:

```text
A recheck sees data and becomes READY
C consumes the data first
A later runs, finds empty, and parks again
```

That is a spurious wakeup, not a correctness bug.

With the current `try_pop()`-based recheck, the actor that succeeds in the
recheck stores the item in `pending_input`, so that particular item is reserved.
Wakeups from producers are still only hints: a woken actor may run and find that
another actor consumed the available item first.

The scheduler promises only:

```text
If an actor is waiting and the condition may have become true, the actor may be
woken.
```

It does not promise:

```text
The woken actor owns the next message or the next free slot.
```

## Deadlock Conditions

For a linear acyclic MoStream pipeline, a correct scheduler should not deadlock
as long as:

```text
sources either produce or close,
sinks keep consuming,
every successful push wakes one input waiter,
every successful pop wakes one output waiter,
parking rechecks input/output conditions,
EOS closes communicators and wakes all input waiters,
stale waiters are skipped,
ready entries are guarded by READY -> RUNNING CAS.
```

Implementation deadlock usually means one of these happened:

```text
lost consumer wakeup,
lost producer wakeup,
stale waiter consumed the only wake attempt,
actor entered a wait queue without changing state,
actor became READY twice and ran twice,
EOS waited forever for bounded queue capacity.
```

Semantic deadlock can still exist in more general graphs with cycles, joins, or
feedback. MoStream's current pipeline model is linear, so most deadlock risk is
implementation-level.

## Memory Ordering Assumptions

Start with `Ordering.SEQUENTIAL` while debugging. It is easier to reason about.

After the protocol is correct, the intended acquire/release pattern is:

```text
RUNNING -> WAITING_* uses RELEASE
WAITING_* -> READY uses RELEASE
READY -> RUNNING uses ACQUIRE
RUNNING -> READY/DONE uses RELEASE
```

The queues must also be thread-safe and linearizable:

```text
ready queue
input_waiters
output_waiters
communicator MPMC queue
```

Memory ordering alone is not enough. The protocol assumes the queue operations
have a well-defined linearization point.

## Single-Worker Prototype

A first implementation can use a single scheduler worker and simpler wait
queues, but it should still keep the same state machine. This avoids designing a
toy protocol that cannot grow into the multi-worker one.

For a single worker:

```text
ready queue can be List[ActorRef]
wait queues can be List[ActorRef]
actor states can be plain Int initially
```

But keep the same logical transitions. When moving to multiple workers, replace
plain state with atomics and wait lists with synchronized queues.

## Heterogeneous Actor Storage

Do not store all actor objects in one list. Store one homogeneous actor pool per
pipeline stage.

```text
StageRuntime[0] owns SourceActor[...]
StageRuntime[1] owns Actor[SecondStage]
StageRuntime[2] owns Actor[ThirdStage]
StageRuntime[3] owns Actor[SinkStage]
```

Queues store:

```text
ActorRef(stage_idx, replica_idx, flat_id)
```

Dispatch uses compile-time stage dispatch:

```mojo
def process_actor(mut self, ref: ActorRef) raises -> Int:
    comptime for i in range(0, Self.N):
        if ref.stage_idx == i:
            return self.stage_runtimes[i].process_replica(ref.replica_idx)

    raise "invalid actor reference"
```

This keeps the actual actor calls statically typed while the scheduling queues
remain homogeneous.

## Recommended Implementation Order

1. Keep the current runtime unchanged.
2. Add non-blocking queue/communicator operations.
3. Implement a single-worker cooperative runtime.
4. Use actor states even in the single-worker version.
5. Add input/output parking primitives with rechecks.
6. Replace EOS queue messages with communicator closed state.
7. Add multi-worker scheduling only after the single-worker protocol is correct.
8. Switch actor state and wait queues to atomic/thread-safe structures.

The most important rule is:

```text
Queue membership is advisory. Actor state is authoritative.
```
