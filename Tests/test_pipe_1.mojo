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

# First test of a pipeline with 3 stages:
#   - FirstStage: source generating numbers from 1 to 1000
#   - SecondStage: stage incrementing each input and converts it to a string
#   - ThirdStage: sink printing each input string received

from std.collections import Optional
from MoStream.communicator import MessageTrait
from MoStream.stage import StageKind, StageTrait
from MoStream.node import NodeTrait, SeqNode, ParallelNode, seq, parallel
from MoStream.pipeline import Pipeline

# FirstStage - Source: generetes numbers from 1 to 1000
struct FirstStage(StageTrait):
    comptime kind = StageKind.SOURCE
    comptime InType = Int
    comptime OutType = Int
    comptime name = "FirstStage"
    var count: Int

    # costructor
    def __init__ (out self):
        self.count = 0

    # next_element implementation
    def next_element(mut self) -> Optional[Int]:
        if self.count > 1000:
            return None
        else:
            self.count = self.count + 1
            return self.count

# SecondStage - increaments the input and converts it to a string
struct SecondStage(StageTrait):
    comptime kind = StageKind.TRANSFORM
    comptime InType = Int
    comptime OutType = String
    comptime name = "SecondStage"

    # costrutor
    def __init__ (out self):
        pass

    # compute implementation
    def compute(mut self, var input: Int) -> Optional[String]:
        input = input + 1
        return String("Valore " + String(input))

# ThirdStage - prints the input string
struct ThirdStage(StageTrait):
    comptime kind = StageKind.SINK
    comptime InType = String
    comptime OutType = String
    comptime name = "ThirdStage"

    # constructor
    def __init__ (out self):
        pass

    # consume_element implementation
    def consume_element(mut self, var input: String) -> None:
        print(input)

# Main
def main() raises:
    # creating the stages
    first_stage = FirstStage()
    second_stage = SecondStage()
    third_stage = ThirdStage()
    # creating the pipeline and running it
    try:
        pipeline = Pipeline((seq(first_stage), seq(second_stage), seq(third_stage)))
        pipeline.setPinning(enabled=False)
        pipeline.run()
    except e:
        print("Execution failed:", e)
