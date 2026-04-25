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

from std.runtime.asyncrt import create_task, TaskGroup, parallelism_level
from std.collections import Optional
from MoStream.communicator import MessageTrait, MessageWrapper, Communicator
from MoStream.stage import StageKind, StageTrait
from MoStream.node import NodeTrait, SeqNode, ParallelNode, seq, parallel
from MoStream.emitter import Emitter
from MoStream.utils import print_cyan_color, print_red_color, print_yellow_color
from std.os import getenv
from std.ffi import OwnedDLHandle, c_int
from std.python import Python

# Executor_task, the function that will be run by each task of the pipeline
#   it executes the logic of a stage and communicates with the other stages through the Communicators
async
def executor_task[NodeT: NodeTrait,
                  In: MessageTrait,
                  Out: MessageTrait, //,
                  idx: Int,
                  len: Int]
                  (mut node: NodeT,
                  inComm: UnsafePointer[mut=True, Communicator[In], _],
                  outComm: UnsafePointer[mut=True, Communicator[Out], _],
                  libFuncC: OwnedDLHandle,
                  cpu_id: Int):
    try:
        var s = node.make_stage() # create the stage to be executed by this task
        # pinning of the underlying thread if pinning is enabled
        if (cpu_id >= 0):
            r = libFuncC.call["pin_thread_to_cpu_checked", c_int](c_int(cpu_id))
            if (r < 0):
                print_yellow_color("{MoStream} Warning: failed to pin thread of stage" + String(NodeT.StageT.name) + "to CPU core" + String(cpu_id))
        comptime if NodeT.StageT.kind == StageKind.SOURCE:
            comptime assert idx == 0, "Source stage must be the first stage of the pipeline"
            execute_source[NodeT.StageT, In, Out](s, inComm, outComm)
        elif NodeT.StageT.kind == StageKind.SINK:
            comptime assert idx == len - 1, "Sink stage must be the last stage of the pipeline"
            execute_sink[NodeT.StageT, In, Out](s, inComm, outComm)
        elif NodeT.StageT.kind == StageKind.TRANSFORM:
            execute_transform[NodeT.StageT, In, Out](s, inComm, outComm)
        elif NodeT.StageT.kind == StageKind.TRANSFORM_MANY:
            execute_transform_many[NodeT.StageT, In, Out](s, inComm, outComm)
        else:
            raise String("Error: Stage") + String(NodeT.StageT.name) + String("has an undefined kind!")
    except e:
        print_red_color("{MoStream} Error: executor_task in stage" + String(NodeT.StageT.name) + "raised a problem -> " + String(e) + "!")

# Execute_source, the function that will be run by the task of a SOURCE stage of the pipeline
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

# Execute_sink, the function that will be run by the task of a SINK stage of the pipeline
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

# Execute_transform, the function that will be run by the task of a TRANSFORM stage of the pipeline
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

# Execute_transform_many, the function that will be run by the task of a TRANSFORM_MANY stage of the pipeline
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

# Pipeline
struct Pipeline[*Ts: NodeTrait]:
    comptime N = len(Self.Ts)
    var nodes: Tuple[*Self.Ts]
    var cpu_ids: List[Int]
    var num_cpus: Int
    var libFuncC: OwnedDLHandle
    var tg: TaskGroup
    var pinning_enabled: Bool
    var last_assigned_cpu: Int
    var queue_size: Int

    # constructor
    def __init__(out self, var nodes: Tuple[*Self.Ts]) raises:
        self.nodes = nodes^
        self.cpu_ids = List[Int]()
        mp = Python.import_module("multiprocessing")
        self.num_cpus = Int(py=mp.cpu_count())
        path_lib = getenv("MOSTREAM_HOME", ".")
        if path_lib == ".":
            print_yellow_color("{MoStream} Warning: MOSTREAM_HOME environment variable not set, using current directory as default")
        path_lib += "/MoStream/lib/libFuncC.so"
        self.libFuncC = OwnedDLHandle(path_lib)
        if not self.libFuncC.check_symbol("pin_thread_to_cpu_checked"):
            raise "Error: symbol pin_thread_to_cpu_checked not found in libFuncC.so"
        self.tg = TaskGroup()
        self.pinning_enabled = False
        self.last_assigned_cpu = 0
        self.queue_size = 1024 # default size of the MPMC queues used for communication between stages
        mapping_str = getenv("MOSTREAM_PINNING", "")
        self.parse_mapping_string(mapping_str)
        if (self.getNumNodes() > parallelism_level()):
            raise("Error: the number of nodes in the pipeline is greater than the number threads available in the thread pool!")

    # _run_from
    # def _run_from[idx: Int, length: Int, M: MessageTrait](mut self, in_comm: UnsafePointer[mut=True, Communicator[M]]):
    def _run_from[idx: Int, length: Int, M: MessageTrait](mut self, in_comm: UnsafePointer[mut=True, Communicator[M], _]):    
        var np = self.nodes[idx].parallelism() # parallelism of node idx
        var nc = 0 # parallelism of the next node idx+1
        comptime if idx < Self.N-1:
            nc = self.nodes[idx+1].parallelism()
        comm = Communicator[Self.Ts[idx].OutType](pN=np, cN=nc, queue_size=self.queue_size)
        out_comm = alloc[Communicator[Self.Ts[idx].OutType]](1)
        out_comm.init_pointee_move(comm^)
        for i in range(0, np):
            var cpu_id: Int # identifier of the CPU core assigned to the task running this stage
            cpu_id = self.cpu_ids[self.last_assigned_cpu + i] if self.pinning_enabled else -1
            self.tg.create_task(executor_task[idx, length](self.nodes[idx],
                                                           in_comm,
                                                           out_comm,
                                                           self.libFuncC,
                                                           cpu_id))
        self.last_assigned_cpu = self.last_assigned_cpu + np
        comptime if idx + 1 < Self.N:
            self._run_from[idx + 1, length, Self.Ts[idx].OutType](out_comm)

    # run
    def run(mut self):
        var status = "disabled"
        if self.pinning_enabled:
            status = "enabled"
        print_cyan_color("{MoStream} Starting pipeline execution with " + String(Self.N) + " stages and total parallelism of " + String(self.getNumNodes()) + " nodes...")
        print_cyan_color("{MoStream} CPU pinning is " + status)
        print_cyan_color("{MoStream} Pipeline starts...")
        comm = Communicator[Self.Ts[0].InType](pN=0, cN=self.nodes[0].parallelism(), queue_size=self.queue_size)
        first_comm = alloc[Communicator[Self.Ts[0].InType]](1)
        first_comm.init_pointee_move(comm^)
        self._run_from[0, Self.N](first_comm)
        self.tg.wait()
        print_cyan_color("{MoStream} ...Pipeline terminated successfully!")

    # parse the cpus list
    def parse_mapping_string(mut self, s: String) raises:
        if (s == ""):
            for i in range(0, self.num_cpus):
                self.cpu_ids.append(i)
        else:
            # split the string by commas
            var parts = s.split(",")
            for part in parts:
                self.cpu_ids.append(Int(part))

    # enable/disable pinning for the pipeline threads
    def setPinning(mut self, enabled: Bool):
        self.pinning_enabled = enabled

    # set the size of the queues used by the communicators between stages
    def setQueueSize(mut self, queue_size: Int):
        self.queue_size = queue_size

    # get number of nodes of this pipeline
    def getNumNodes(self) -> Int:
        var total_nodes = 0
        comptime for i in range(0, Self.N):
            total_nodes += self.nodes[i].parallelism()
        return total_nodes
