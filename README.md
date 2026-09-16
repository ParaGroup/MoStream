# MoStream Adaptive Runtime v1

This branch is for the first adaptive-runtime idea in MoStream.

The goal is to run a stream-processing pipeline with a fixed pool of scheduler
workers while changing the effective parallelism of each stage at run time.

Instead of choosing one static parallelism degree per stage before execution,
the runtime observes the pipeline while it runs:

- if a stage input queue grows and its output queue is not congested, the stage
  is treated as a bottleneck and can receive more active actors;
- if a stage has little input work or is blocked by downstream pressure, some of
  its actors can be made quiet;
- quiet actors still exist, but they are not scheduled until the controller
  activates them again.

In short:

```text
fixed workers + many possible stage replicas + feedback from queues
    -> dynamically choose where parallelism is useful
```

This is useful for pipelines whose bottleneck changes over time, or whose best
per-stage parallelism is not known before execution.
