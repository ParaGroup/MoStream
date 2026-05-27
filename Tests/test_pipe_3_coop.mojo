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

# Third test of a pipeline with 4 stages using the cooperative runtime:
#   - FirstStage: source generating numbers from 1 to 1000
#   - SecondStage: parallel stage forwarding the received number
#   - ThirdStage: parallel stage forwarding the received number
#   - FourthStage: sink counting the total sum of all received inputs

from std.collections import Optional
from MoStream import StageKind, StageTrait
from MoStream import seq, parallel
from MoStream import Pipeline
from std.sys import argv

# FirstStage - Source: generetes numbers from 1 to 1000
struct FirstStage(StageTrait):
    comptime kind = StageKind.SOURCE
    comptime InType = Int
    comptime OutType = Int
    comptime name = "FirstStage"
    var count: Int

    # constructor
    def __init__ (out self):
        self.count = 0

    # next_element implementation
    def next_element(mut self) -> Optional[Int]:
        if self.count >= 1000:
            return None
        else:
            self.count = self.count + 1
            return self.count

# SecondStage - forward the received number
struct SecondStage(StageTrait):
    comptime kind = StageKind.TRANSFORM
    comptime InType = Int
    comptime OutType = Int
    comptime name = "SecondStage"

    # constructor
    def __init__ (out self):
        pass

    # compute implementation
    def compute(mut self, var input: Int) -> Int:
        return input

# ThirdStage - forward the received number
struct ThirdStage(StageTrait):
    comptime kind = StageKind.TRANSFORM
    comptime InType = Int
    comptime OutType = Int
    comptime name = "ThirdStage"

    # constructor
    def __init__ (out self):
        pass

    # compute implementation
    def compute(mut self, var input: Int) -> Int:
        return input

# FourthStage - prints the input string
struct FourthStage(StageTrait):
    comptime kind = StageKind.SINK
    comptime InType = Int
    comptime OutType = Int
    comptime name = "FourthStage"
    var sum: Int

    # constructor
    def __init__ (out self):
        self.sum = 0

    # consume_element implementation
    def consume_element(mut self, var input: Int) -> None:
        self.sum = self.sum + input

    # receive_eof implementation
    def received_eos(mut self):
        print("Total sum: ", self.sum)

# Main
def main():
    var args = argv()
    if len(args) != 2:
        print("Usage: ./test_pipe_3_coop <n_workers>")
        print("  n_workers = number of workers used by the cooperative scheduler")
        return
    # creating the stages
    first_stage = FirstStage()
    second_stage = SecondStage()
    third_stage = ThirdStage()
    fourth_stage = FourthStage()
    # creating the pipeline and running it
    try:
        var n_workers = Int(args[1])
        pipeline = Pipeline((parallel(first_stage,2), parallel(second_stage, 2), parallel(third_stage, 3), parallel(fourth_stage, 3)))
        pipeline.setPinning(enabled=False)        
        pipeline.run_cooperative(n_workers)
    except e:
        print("Execution failed:", e)
