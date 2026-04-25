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

from MoStream.stage import StageTrait
from MoStream.communicator import MessageTrait

# A pipeline node is either a single stage or a parallel stage
trait NodeTrait(ImplicitlyCopyable):
    comptime StageT: StageTrait
    comptime InType: MessageTrait
    comptime OutType: MessageTrait

    # return the parallelism of this node (number of replicas)
    def parallelism(self) -> Int:
        ...

    # return a copy of the stage instance
    def make_stage(self) -> Self.StageT:
        ...

# SeqNode is a node with parallelism 1
@fieldwise_init
struct SeqNode[st: StageTrait](NodeTrait):
    comptime StageT = Self.st
    comptime InType = Self.StageT.InType
    comptime OutType = Self.StageT.OutType
    var stage: Self.StageT

    # return the parallelism of this node (number of replicas)
    def parallelism(self) -> Int:
        return 1

    # return a copy of the stage instance
    def make_stage(self) -> Self.StageT:
        return self.stage

# ParallelNode is a node with parallelism > 1
@fieldwise_init
struct ParallelNode[st: StageTrait](NodeTrait):
    comptime StageT = Self.st
    comptime InType = Self.StageT.InType
    comptime OutType = Self.StageT.OutType
    var stage: Self.st
    var parDegree: Int

    # return the parallelism of this node (number of replicas)
    def parallelism(self) -> Int:
        return self.parDegree

    # return a copy of the stage instance
    def make_stage(self) -> Self.StageT:
        return self.stage

# Helper function to create a SeqNode
def seq[StageT: StageTrait](stage: StageT) -> SeqNode[StageT]:
    return SeqNode[StageT](stage=stage)

# Helper function to create a ParallelNode
def parallel[StageT: StageTrait](stage: StageT, parDegree: Int) -> ParallelNode[StageT]:
    return ParallelNode[StageT](stage=stage, parDegree=parDegree)
