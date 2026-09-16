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
from MoStream.actor import Actor
from MoStream.utils import print_red_color
from std.memory.alloc import unsafe_alloc
from std.memory import Pointer

# General trait of a pipeline node
trait NodeTrait(Movable & Deinitable):
    comptime StageT: StageTrait

    # return the parallelism degree
    def parallelism(self) -> Int:
        ...

    # return a copy of the stage of this node
    def make_stage(self) -> Self.StageT:
        ...

    # add an actor running this node (used by the cooperative runtime)
    def add_actor(mut self, var actor: Actor[Self.StageT]) raises:
        ...

    # return a pointer to the actor with the given replica index (used by the cooperative runtime)
    def actor_ref(ref self, replica_idx: Int) raises -> Pointer[Actor[Self.StageT], MutUntrackedOrigin]:
        ...

# SeqNode is a pipeline node with parallelism 1
struct SeqNode[st: StageTrait](NodeTrait):
    comptime StageT = Self.st
    var stage: Self.StageT
    var actors: Pointer[Actor[Self.StageT], MutUntrackedOrigin]
    var actor_count: Int

    # constructor
    def __init__(out self, *, stage: Self.StageT):
        self.stage = stage.copy()
        self.actors = unsafe_alloc[Actor[Self.StageT]](1) # space for one actor only
        self.actor_count = 0

    # destructor
    def __deinit__(deinit self):
        for i in range(self.actor_count):
            self.actors.unsafe_offset(i).unsafe_deinit_pointee()
        self.actors.unsafe_free()

    # return the parallelism degree
    def parallelism(self) -> Int:
        return 1

    # return a copy of the stage of this node
    def make_stage(self) -> Self.StageT:
        return self.stage.copy()

    # add an actor running this node (used by the cooperative runtime)
    def add_actor(mut self, var actor: Actor[Self.StageT]) raises:
        if self.actor_count >= 1:
            print_red_color("{MoStream} Error: SeqNode can only have one actor!")
            raise Error("error in add_actor()")
        self.actors.unsafe_offset(self.actor_count).unsafe_write(actor^)
        self.actor_count += 1

    # return a pointer to the actor with the given replica index (used by the cooperative runtime)
    def actor_ref(ref self, replica_idx: Int) raises -> Pointer[Actor[Self.StageT], MutUntrackedOrigin]:
        if replica_idx != 0:
            print_red_color("{MoStream} Error: SeqNode only has one actor with replica index 0!")
            raise Error("error in actor_ref()")
        return self.actors

# ParallelNode is a set of nodes running the same pipeline stage
struct ParallelNode[st: StageTrait](NodeTrait):
    comptime StageT = Self.st
    var stage: Self.st
    var parDegree: Int
    var actors: Pointer[Actor[Self.StageT], MutUntrackedOrigin]
    var actor_count: Int

    # constructor
    def __init__(out self, *, stage: Self.StageT, parDegree: Int):
        self.stage = stage.copy()
        self.parDegree = parDegree
        self.actors = unsafe_alloc[Actor[Self.StageT]](parDegree) # space for parDegree actors
        self.actor_count = 0

    # destructor
    def __deinit__(deinit self):
        for i in range(self.actor_count):
            self.actors.unsafe_offset(i).unsafe_deinit_pointee()
        self.actors.unsafe_free()

    # return the parallelism degree
    def parallelism(self) -> Int:
        return self.parDegree

    # return a copy of the stage of this node
    def make_stage(self) -> Self.StageT:
        return self.stage.copy()

    # add an actor running this node (used by the cooperative runtime)
    def add_actor(mut self, var actor: Actor[Self.StageT]) raises:
        if self.actor_count >= self.parDegree:
            print_red_color("{MoStream} Error: ParallelNode can only have " + String(self.parDegree) + " actors!")
            raise Error("error in add_actor()")
        self.actors.unsafe_offset(self.actor_count).unsafe_write(actor^)
        self.actor_count += 1

    # return a pointer to the actor with the given replica index (used by the cooperative runtime)
    def actor_ref(ref self, replica_idx: Int) raises -> Pointer[Actor[Self.StageT], MutUntrackedOrigin]:
        if replica_idx >= self.actor_count:
            print_red_color("{MoStream} Error: invalid replica index accessed with actor_ref()!")
            raise Error("error in actor_ref()")
        return self.actors.unsafe_offset(replica_idx)

# Helper function to create a SeqNode
def seq[StageT: StageTrait](stage: StageT) -> SeqNode[StageT]:
    return SeqNode[StageT](stage=stage)

# Helper function to create a ParallelNode
def parallel[StageT: StageTrait](stage: StageT, parDegree: Int) -> ParallelNode[StageT]:
    return ParallelNode[StageT](stage=stage, parDegree=parDegree)
