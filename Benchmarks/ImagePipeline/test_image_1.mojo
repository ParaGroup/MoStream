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

# Image processing pipeline benchmark in Mojo using the standard runtime:
#   - TimedImageSource: source generating copies of the same image for a fixed duration
#   - GrayScaleFilter: converts input image to grayscale
#   - GaussianBlur: applies a 3x3 Gaussian blur to the input image
#   - Sharpen: applies a 3x3 sharpening filter to the input image
#   - ImageSink: receives processed images, counts them, and prints final stats on EOS
#   The intermediate stages can be parallel, the source and sink are always single-threaded.

from MoStream import Pipeline, seq, parallel
from image_stages import TimedImageSource, Grayscale, GaussianBlur, Sharpen, ImageSink
from std.time import perf_counter_ns
from std.sys import argv

comptime W: Int = 512
comptime H: Int = 512
comptime DURATION: Int = 60
comptime BASELINE_N: Int = 5000

# Utility functions
def elapsed_ms(t0: UInt) -> Float64:
    return Float64(Int(perf_counter_ns() - t0)) / 1_000_000.0

# Throughput in images per second
def throughput(n: Int, ms: Float64) -> Float64:
    if ms <= 0.0: return 0.0
    return Float64(n) / (ms / 1000.0)

# Run a given configuration of the pipeline
def run_config(src_degree: Int, gray_degree: Int, blur_degree: Int, sharp_degree: Int, sink_degree: Int) raises -> Tuple[Int, Float64]:
    var source = TimedImageSource[W, H, DURATION]()
    var gray = Grayscale()
    var blur = GaussianBlur()
    var sharp = Sharpen()
    var sink = ImageSink()
    var count_ptr = sink.count_ptr
    var pipeline = Pipeline((parallel(source, src_degree), parallel(gray, gray_degree), parallel(blur, blur_degree), parallel(sharp, sharp_degree), parallel(sink, sink_degree)))
    pipeline.setPinning(True)
    var t0 = perf_counter_ns()
    pipeline.run()
    var ms = elapsed_ms(t0)
    var n = count_ptr[]
    count_ptr.free()
    _ = pipeline
    return (n, ms)

# Main
def main():
    var args = argv()
    if len(args) != 6:
        print("Usage: ./test_image_coop <Source> <GrayScale> <GaussianBlur> <Sharpen> <Sink>")
        return
    try:
        var src_degree = Int(args[1])
        var gray_degree = Int(args[2])
        var blur_degree = Int(args[3])
        var sharp_degree = Int(args[4])
        var sink_degree = Int(args[5])
        print("  Image processing pipeline in Mojo: Source -> GrayScale -> GaussianBlur -> Sharpen -> Sink")
        print("  Configuration: Source=" + String(src_degree) + " GrayScale=" + String(gray_degree) + " GaussianBlur=" + String(blur_degree) + " Sharpen=" + String(sharp_degree) + " Sink=" + String(sink_degree))
        var res = run_config(src_degree, gray_degree, blur_degree, sharp_degree, sink_degree)
        var n = res[0]; var ms = res[1]
        var tput = throughput(n, ms)
        print("Elapsed time: " + String(ms) + " ms")
        print("Throughput: " + String(tput) + " img/s")
    except e:
        print("Execution failed:", e)
