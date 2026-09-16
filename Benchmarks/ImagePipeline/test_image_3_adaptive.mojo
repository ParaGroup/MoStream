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

# Image processing pipeline benchmark in Mojo using the adaptive cooperative runtime:
#   - TimedImageSource: source generating copies of the same image for a fixed duration
#   - AlternatingFilterStage: alternate GaussianBlur or Sharpen for a fixed time duration
#   - AlternatingFilterStage: alternate GaussianBlur or Sharpen for a fixed time duration, opposite to the previous stage
#   - ImageSink: receives processed images, counts them, and prints final stats on EOS
#   The intermediate stages can be parallel, the source and sink are always single-threaded.

from MoStream import Pipeline, seq, parallel
from image_stages import TimedImageSource, GaussianBlur, Sharpen, AlternatingFilterStage, ImageSink
from std.atomic import Atomic, Ordering
from std.time import perf_counter_ns
from std.sys import argv
from std.memory.alloc import unsafe_alloc
from std.memory import Pointer

comptime W: Int = 512
comptime H: Int = 512
comptime DURATION: Int = 60
comptime BASELINE_N: Int = 5000

# Utility functions
def elapsed_ms(t0: Int) -> Float64:
    return Float64(Int(perf_counter_ns() - t0)) / 1_000_000.0

# Throughput in images per second
def throughput(n: Int, ms: Float64) -> Float64:
    if ms <= 0.0: return 0.0
    return Float64(n) / (ms / 1000.0)

# Run a given configuration of the pipeline
def run_config(src_degree: Int, alternate_degree_1: Int, alternate_degree_2: Int, sink_degree: Int, n_workers: Int) raises -> Tuple[Int, Float64]:
    var source = TimedImageSource[W, H, DURATION]()
    var alt1 = AlternatingFilterStage[DURATION](True)
    var alt2 = AlternatingFilterStage[DURATION](False)
    var count_ptr = unsafe_alloc[Atomic[DType.int64]](1)
    count_ptr[] = Atomic[DType.int64](Int64(0))
    var sink = ImageSink(count_ptr)
    var pipeline = Pipeline((parallel(source, src_degree), parallel(alt1, alternate_degree_1), parallel(alt2, alternate_degree_2), parallel(sink, sink_degree)))
    pipeline.setPinning(True)
    var t0 = perf_counter_ns()
    pipeline.run_cooperative_adaptive(n_workers)
    var ms = elapsed_ms(t0)
    var n = Int(count_ptr[].load[ordering=Ordering.ACQUIRE]())
    count_ptr.unsafe_deinit_pointee()
    count_ptr.unsafe_free()
    _ = pipeline
    return (n, ms)

# Main
def main():
    var args = argv()
    if len(args) != 6:
        print("Usage: ./test_image_coop <maxSource> <maxAlternate1> <maxAlternate2> <maxSink> <Workers>")
        return
    try:
        var src_degree = Int(args[1])
        var alternate_degree_1 = Int(args[2])
        var alternate_degree_2 = Int(args[3])
        var sink_degree = Int(args[4])
        var n_workers = Int(args[5])
        print("  Image processing pipeline in Mojo: Source -> AlternatingFilterStage -> AlternatingFilterStage -> Sink")
        print("  Configuration: Source=" + String(src_degree) + " Alternate1=" + String(alternate_degree_1) + " Alternate2=" + String(alternate_degree_2) + " Sink=" + String(sink_degree) + " Workers=" + String(n_workers))
        var res = run_config(src_degree, alternate_degree_1, alternate_degree_2, sink_degree, n_workers)
        var n = res[0]; var ms = res[1]
        var tput = throughput(n, ms)
        print("Elapsed time: " + String(ms) + " ms")
        print("Throughput: " + String(tput) + " img/s")
    except e:
        print("Execution failed:", e)
