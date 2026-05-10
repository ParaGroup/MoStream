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
from MoStream.communicator import MessageTrait, MessageWrapper, Communicator
from MoStream.stage import StageKind, StageTrait
from MoStream.node import NodeTrait
from MoStream.emitter import Emitter
from MoStream.pipeline import Pinning
from MoStream.utils import print_red_color
from std.sys.terminate import exit
from std.ffi import OwnedDLHandle, c_int

# Executor_task: the function that will be run by each task of the pipeline,
#   executing the logic of a stage and communicates with the other stages through the Communicators
async
def executor_task[NodeT: NodeTrait,
                 In: MessageTrait,
                 Out: MessageTrait, //,
                 idx: Int,
                 len: Int]
                 (mut node: NodeT,
                 inComm: UnsafePointer[mut=True, Communicator[In], _],
                 outComm: UnsafePointer[mut=True, Communicator[Out], _],
                 core_id: Int,
                 mut pinning_handler: Pinning):
    try:
        var s = node.make_stage() # create a copy of the stage executed by this task
        # pinning of the underlying thread if pinning is enabled
        if (core_id >= 0):
            _ = pinning_handler.pin_on_the_core(core_id)
        comptime if NodeT.StageT.kind == StageKind.SOURCE:
            execute_source[NodeT.StageT, In, Out](s, inComm, outComm)
        elif NodeT.StageT.kind == StageKind.SINK:
            execute_sink[NodeT.StageT, In, Out](s, inComm, outComm)
        elif NodeT.StageT.kind == StageKind.TRANSFORM:
            execute_transform[NodeT.StageT, In, Out](s, inComm, outComm)
        elif NodeT.StageT.kind == StageKind.TRANSFORM_MANY:
            execute_transform_many[NodeT.StageT, In, Out](s, inComm, outComm)
        else:
            print_red_color("{MoStream} Error: " + String("stage ") + String(NodeT.StageT.name) + String(" has an undefined kind!"))
            raise Error("error in executor_task()")
    except e:
        print("Raised: " + String(e))
        exit(1)

# Execute_source: the function that will be run by the task of a SOURCE stage of the pipeline
def execute_source[Stage: StageTrait,
                  In: MessageTrait,
                  Out: MessageTrait]
                  (mut s: Stage,
                  inComm: UnsafePointer[mut=True, Communicator[In], _],
                  outComm: UnsafePointer[mut=True, Communicator[Out], _]) raises:
    var end_of_stream = False
    while (not end_of_stream):
        output = s.next_element()
        if output == None:
            end_of_stream = True
            outComm[].producer_finished()
            s.received_eos()
        else:
            outComm[].push(MessageWrapper[Out](data = rebind[Optional[Out]](output).take(), eos = False))
    # destroy the input communicator
    if (inComm[].check_isDestroyable()):
        inComm.destroy_pointee()
        inComm.free()

# Execute_sink: the function that will be run by the task of a SINK stage of the pipeline
def execute_sink[Stage: StageTrait,
                In: MessageTrait,
                Out: MessageTrait]
                (mut s: Stage,
                inComm: UnsafePointer[mut=True, Communicator[In], _],
                outComm: UnsafePointer[mut=True, Communicator[Out], _]) raises:
    var end_of_stream = False
    while (not end_of_stream):
        input = inComm[].pop()
        if input.eos:
            end_of_stream = True
            s.received_eos()
        else:
            s.consume_element(rebind[MessageWrapper[Stage.InType]](input).data.take())
    # destroy the output and input communicators
    outComm.destroy_pointee()
    outComm.free()
    if (inComm[].check_isDestroyable()):
        inComm.destroy_pointee()
        inComm.free()

# Execute_transform: the function that will be run by the task of a TRANSFORM stage of the pipeline
def execute_transform[Stage: StageTrait,
                     In: MessageTrait,
                     Out: MessageTrait]
                     (mut s: Stage,
                     inComm: UnsafePointer[mut=True, Communicator[In], _],
                     outComm: UnsafePointer[mut=True, Communicator[Out], _]) raises:
    var end_of_stream = False
    while (not end_of_stream):
        input = inComm[].pop()
        if input.eos:
            end_of_stream = True
            outComm[].producer_finished()
            s.received_eos()
        else:
            output = s.compute(rebind[MessageWrapper[Stage.InType]](input).data.take())
            if (output != None):
                outComm[].push(MessageWrapper[Out](data = rebind[Optional[Out]](output).take(), eos = False))
    # destroy the input communicator
    if (inComm[].check_isDestroyable()):
        inComm.destroy_pointee()
        inComm.free()

# Execute_transform_many: the function that will be run by the task of a TRANSFORM_MANY stage of the pipeline
def execute_transform_many[Stage: StageTrait,
                          In: MessageTrait,
                          Out: MessageTrait]
                          (mut s: Stage,
                          inComm: UnsafePointer[mut=True, Communicator[In], _],
                          outComm: UnsafePointer[mut=True, Communicator[Out], _]) raises:
    var end_of_stream = False
    var e = Emitter(outComm)
    while (not end_of_stream):
        input = inComm[].pop()
        if input.eos:
            end_of_stream = True
            outComm[].producer_finished()
            s.received_eos()
        else:
            output = s.compute_many(rebind[MessageWrapper[Stage.InType]](input).data.take(), rebind[Emitter[Stage.OutType]](e))
    # destroy the input communicator
    if (inComm[].check_isDestroyable()):
        inComm.destroy_pointee()
        inComm.free()
