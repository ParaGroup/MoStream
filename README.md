[![License: LGPL v3](https://img.shields.io/badge/License-LGPL%20v3-blue.svg)](https://www.gnu.org/licenses/lgpl-3.0)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://paypal.me/GabrieleMencagli)
![MoStream Logo](https://raw.githubusercontent.com/ParaGroup/MoStream/main/Logo/mostream_small.png)

# MoStream

MoStream is a Mojo library for building stream-processing pipelines with
sequential and parallel stages. A pipeline is composed from user-defined stages
connected by inter-stage communicators, then executed by Mojo async tasks.

The library is intended for workloads that naturally fit a flow such as:

```text
source -> stage -> stage -> ... -> sink
```

Each stage declares its input and output message types, and can be run as a
sequential node (thread), or as a collection of parallel nodes (threads each
running a replica of the stage).

## Features

- Source, transform, one-to-many transform, and sink stages.
- Sequential nodes with `seq(stage)`.
- Replicated parallel nodes with `parallel(stage, degree)`.
- Optional CPU pinning through a small C helper library.
- Configurable communicators (e.g., customizable queue size).

## Repository Layout

```text
MoStream/
  __init__.mojo          Public exports
  pipeline.mojo          Pipeline scheduler and executor
  stage.mojo             Stage trait and stage kinds
  node.mojo              Sequential and parallel pipeline nodes
  communicator.mojo      Message wrappers and communicator
  MPMC_queue.mojo        Bounded lock-free MPMC queue
  emitter.mojo           Output emitter for one-to-many stages
  lib/                   C helper used for CPU affinity

Tests/
  test_pipe_1.mojo       Source -> transform -> sink example
  test_pipe_2.mojo       Source -> transform_many -> sink example
  test_pipe_3.mojo       Parallel transform stages example

Benchmarks/
  ImagePipeline/         Image-processing pipeline benchmark
```

## Requirements

- Mojo toolchain (version >= 0.26.3)
- A C compiler such as `gcc` for the CPU-affinity helper.
- Linux-style pthread CPU affinity support for thread pinning.

The current runtime expects the helper library at:

```text
$MOSTREAM_HOME/MoStream/lib/libFuncC.so
```

## Setup

Build the C helper and point `MOSTREAM_HOME` at the repository root:

```sh
make -C MoStream/lib
export MOSTREAM_HOME="$PWD"
```

Then run one of the included examples:

```sh
mojo Tests/test_pipe_1.mojo
```

If `MOSTREAM_HOME` is not set, MoStream falls back to the current directory.

## Quick Example

```mojo
from std.collections import Optional
from MoStream import Pipeline, StageKind, StageTrait, seq, parallel

struct NumberSource(StageTrait):
    comptime kind = StageKind.SOURCE
    comptime InType = Int
    comptime OutType = Int
    comptime name = "NumberSource"
    var next: Int

    def __init__(out self):
        self.next = 1

    def next_element(mut self) -> Optional[Int]:
        if self.next > 100:
            return None
        var value = self.next
        self.next = self.next + 1
        return value

struct AddOne(StageTrait):
    comptime kind = StageKind.TRANSFORM
    comptime InType = Int
    comptime OutType = Int
    comptime name = "AddOne"

    def compute(mut self, var input: Int) -> Optional[Int]:
        return input + 1

struct PrintSink(StageTrait):
    comptime kind = StageKind.SINK
    comptime InType = Int
    comptime OutType = Int
    comptime name = "PrintSink"

    def consume_element(mut self, var input: Int):
        print(input)

def main() raises:
    var source = NumberSource()
    var add_one = AddOne()
    var sink = PrintSink()

    var pipeline = Pipeline((
        seq(source),
        parallel(add_one, 4),
        seq(sink),
    ))

    pipeline.setPinning(False)
    pipeline.run()
```

## Defining Stages

Every stage implements `StageTrait` and sets these compile-time fields:

```mojo
comptime kind: Int
comptime InType: MessageTrait
comptime OutType: MessageTrait
comptime name: String
```

Supported stage kinds:

- `StageKind.SOURCE`: produces stream elements with `next_element()`.
- `StageKind.TRANSFORM`: consumes one input and returns zero or one output with
  `compute()`.
- `StageKind.TRANSFORM_MANY`: consumes one input and emits zero or more outputs
  with `compute_many(input, emitter)`.
- `StageKind.SINK`: consumes stream elements with `consume_element()`.

Stages can optionally implement:

```mojo
def received_eos(mut self):
    ...
```

MoStream calls this hook when a stage observes the end of the stream.

## One-to-Many Transforms

`TRANSFORM_MANY` stages use `Emitter` to produce any number of output elements
for a single input:

```mojo
from MoStream import Emitter

struct Duplicate(StageTrait):
    comptime kind = StageKind.TRANSFORM_MANY
    comptime InType = Int
    comptime OutType = Int
    comptime name = "Duplicate"

    def compute_many(mut self, var input: Int, mut emitter: Emitter[Int]):
        emitter.emit(input)
        emitter.emit(input)
```

## Parallelism

Use `seq(stage)` for a single stage instance and `parallel(stage, degree)` for
replicated execution:

```mojo
var pipeline = Pipeline((
    seq(source),
    parallel(filter, 4),
    parallel(mapper, 8),
    seq(sink),
))
```

The source stage must be the first pipeline stage, and the sink stage must be
the last. The total number of node replicas must fit within Mojo's available
async runtime parallelism.

## Runtime Configuration

### Queue Size

MoStream currently adopt just one communicator type. This uses bounded MPMC queues
between stages. The default queue size is `1024`. Queue sizes must be powers of two
and at least `2`.

```mojo
pipeline.setQueueSize(2048)
```

### CPU Pinning

CPU pinning is disabled by default.

```mojo
pipeline.setPinning(True)
```

By default, MoStream assigns CPU IDs from `0` to the number of detected CPUs.
You can provide a custom CPU order with `MOSTREAM_PINNING`:

```sh
export MOSTREAM_PINNING="0,2,4,6"
```

## Benchmarks

The image benchmark demonstrates a deeper stream-processing graph:

```text
TimedImageSource -> Grayscale -> GaussianBlur -> Sharpen -> ImageSink
```

Run it with the parallelism degree for each transform stage:

```sh
mojo Benchmarks/ImagePipeline/test_image_pipeline.mojo 2 4 2
```

## License

Source file headers state that MoStream is distributed under the GNU Lesser
General Public License version 3.

## Requests for Modifications
If you are using MoStream for your purposes and you are interested in specific modifications of the API (or of the runtime system), please send an email to the maintainer.

## Contributors
The main developer and maintainer of MoStream is [Gabriele Mencagli](mailto:gabriele.mencagli@unipi.it) (Department of Computer Science, University of Pisa, Italy).