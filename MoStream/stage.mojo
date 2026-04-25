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

from std.collections import Optional
from MoStream.communicator import MessageTrait
from MoStream.emitter import Emitter

# Types of stages supported by the Pipeline
struct StageKind:
    comptime SOURCE: Int = 0
    comptime TRANSFORM: Int = 1
    comptime TRANSFORM_MANY: Int = 2
    comptime SINK: Int = 3
    comptime NOTDEFINED: Int = 4

# Generic trait of stages in the pipeline, with default implementations that raise errors if not overridden
trait StageTrait(ImplicitlyCopyable):
    comptime kind = StageKind.NOTDEFINED
    comptime InType: MessageTrait
    comptime OutType: MessageTrait
    comptime name: String = "No name"

    # next_element (stage SOURCE)
    #   generate the next element of the stream, returns an Optional containing the element if generated successfully, or None if the stream has ended
    def next_element(mut self) raises -> Optional[Self.OutType]:
        raise String("Error: Stage ") + String(Self.name) + String(" does not implement the next_element() method!")

    # compute (stage TRANSFORM)
    #   generate one or zero output elements for the input element
    def compute(mut self, var input: Self.InType) raises -> Optional[Self.OutType]:
        raise String("Error: Stage ") + String(Self.name) + String(" does not implement the compute() method!")

    # compute_many (stage TRANSFORM_MANY)
    #   generate one, zero or more output elements for the input element
    def compute_many(mut self, var input: Self.InType, mut e: Emitter[Self.OutType]) raises:
        raise String("Error: Stage ") + String(Self.name) + String(" does not implement the compute_many() method!")

    # consume_element (stage SINK)
    #   consume one input element
    def consume_element(mut self, var input: Self.InType) raises:
        raise String("Error: Stage ") + String(Self.name) + String(" does not implement the consume_element() method!")

    # received_eos (all stages)
    #   react to the end of the stream, perform any necessary cleanup
    def received_eos(mut self):
        pass
