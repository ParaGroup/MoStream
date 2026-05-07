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

from MoStream.stage import StageKind, StageTrait
from MoStream.communicator import MessageTrait, Communicator, MessageWrapper
from MoStream.utils import print_cyan_color, print_red_color, print_yellow_color

# The actor activation might produce one of the following statuses:
struct ActorStatus:
    comptime READY: UInt64 = 0 # ready to be scheduled again
    comptime RUNNING: UInt64 = 1 # currently running, should not be scheduled again until it finishes
    comptime BLOCKED_INPUT: UInt64 = 2 # blocked on input, cannot be scheduled until some input arrives
    comptime BLOCKED_OUTPUT: UInt64 = 3 # blocked on output, cannot be scheduled until some output is consumed
    comptime DONE: UInt64 = 4  # done, will not be scheduled again
    comptime ERROR: UInt64 = 5 # error, will not be scheduled again

# An actor associated with a pipeline node
struct Actor[StageT: StageTrait](Copyable & ImplicitlyDestructible):
    var stage: Self.StageT
    var in_comm: UnsafePointer[Communicator[Self.StageT.InType], MutAnyOrigin]
    var out_comm: UnsafePointer[Communicator[Self.StageT.OutType], MutAnyOrigin]
    var pending_input: Optional[MessageWrapper[Self.StageT.InType]]
    var pending_output: Optional[MessageWrapper[Self.StageT.OutType]]
    var done: Bool

    # constructor
    def __init__(out self,
                stage: Self.StageT,
                in_comm: UnsafePointer[mut=True, Communicator[Self.StageT.InType], _],
                out_comm: UnsafePointer[mut=True, Communicator[Self.StageT.OutType], _]):
        self.stage = stage.copy()
        self.in_comm = in_comm
        self.out_comm = out_comm
        self.pending_input = None
        self.pending_output = None
        self.done = False

    # get a new input (the pending one or try to pop from the input communicator)
    def take_or_try_pop_input(mut self) -> Optional[MessageWrapper[Self.StageT.InType]]:
        if self.pending_input:
            return Optional(self.pending_input.take())
        return self.in_comm[].try_pop()

    # try to pop an input for parking, returns true if successful
    def try_pop_input_for_parking(mut self) -> Bool:
        var maybe_msg = self.in_comm[].try_pop()
        if maybe_msg:
            self.pending_input = maybe_msg^
            return True
        return False

    # retry pushing the pending output
    def retry_push_pending_output(mut self) -> Bool:
        if not self.pending_output:
            return True
        var not_delivered = self.out_comm[].try_push(self.pending_output.take())
        if not_delivered:
            self.pending_output = not_delivered^
            return False
        return True

    # actor process (SOURCE)
    def process_source(mut self) raises -> UInt64:
        if self.done:
            return ActorStatus.DONE
        if not self.retry_push_pending_output():
            return ActorStatus.BLOCKED_OUTPUT
        var maybe_output = self.stage.next_element()
        if not maybe_output:
            self.done = True
            self.out_comm[].producer_finished()
            self.stage.received_eos()
            return ActorStatus.DONE
        var msg = MessageWrapper[Self.StageT.OutType](data=rebind[Optional[Self.StageT.OutType]](maybe_output).take(), eos=False)
        var not_delivered = self.out_comm[].try_push(msg^)
        if not_delivered:
            self.pending_output = not_delivered^
            return ActorStatus.BLOCKED_OUTPUT
        return ActorStatus.READY

    # process actor (TRANSFORM)
    def process_transform(mut self) raises -> UInt64:
        if self.done:
            return ActorStatus.DONE
        if not self.retry_push_pending_output():
            return ActorStatus.BLOCKED_OUTPUT
        var maybe_input = self.take_or_try_pop_input()
        if not maybe_input:
            return ActorStatus.BLOCKED_INPUT
        var input = maybe_input.take()
        if input.eos:
            self.done = True
            self.out_comm[].producer_finished()
            self.stage.received_eos()
            return ActorStatus.DONE
        var maybe_output = self.stage.compute(rebind[MessageWrapper[Self.StageT.InType]](input).data.take())
        if maybe_output:
            var output = MessageWrapper[Self.StageT.OutType](data=rebind[Optional[Self.StageT.OutType]](maybe_output).take(), eos=False)
            var not_delivered = self.out_comm[].try_push(output^)
            if not_delivered:
                self.pending_output = not_delivered^
                return ActorStatus.BLOCKED_OUTPUT
        return ActorStatus.READY

    # process actor (SINK)
    def process_sink(mut self) raises -> UInt64:
        if self.done:
            return ActorStatus.DONE
        var maybe_input = self.take_or_try_pop_input()
        if not maybe_input:
            return ActorStatus.BLOCKED_INPUT
        var input = maybe_input.take()
        if input.eos:
            self.done = True
            self.stage.received_eos()
            return ActorStatus.DONE
        self.stage.consume_element(rebind[MessageWrapper[Self.StageT.InType]](input).data.take())
        return ActorStatus.READY

    # main process of the actor
    def process(mut self) -> UInt64:
        try:
            comptime if Self.StageT.kind == StageKind.SOURCE:
                return self.process_source()
            elif Self.StageT.kind == StageKind.TRANSFORM:
                return self.process_transform()
            elif Self.StageT.kind == StageKind.SINK:
                return self.process_sink()
            else:
                raise "invalid stage kind in the actor process()"
        except e:
            print_red_color("{MoStream} Error: " + String(e) + "!")
        return ActorStatus.ERROR
