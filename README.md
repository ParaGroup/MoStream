# MoStream Adaptive Scheduler

This branch explores a simple adaptive scheduler for MoStream.

The idea is to avoid fixing the parallelism of every pipeline stage before the
program starts. Instead, the runtime observes the pipeline while it executes and
adjusts how many actors of each stage are actively scheduled.

Each stage can have more actor replicas available than the scheduler is
currently using. The adaptive controller decides which replicas should be active
based on the state of the neighboring queues.

Conceptually:

```text
high input pressure + free output capacity -> stage may need more actors
low input pressure or blocked output       -> stage may have too many actors
```

The scheduler therefore tries to move parallelism toward the current bottleneck
and away from stages that are idle or backpressured.

The goal is not to maximize the number of actors, but to use the available
worker threads where they are most useful as the bottleneck of the stream
changes over time.
