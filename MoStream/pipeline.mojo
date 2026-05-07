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
from MoStream.communicator import MessageTrait, Communicator
from MoStream.node import NodeTrait, seq, parallel
from MoStream.emitter import Emitter
from MoStream.runtime import executor_task
from MoStream.scheduler import Scheduler
from MoStream.actor import Actor
from MoStream.utils import print_cyan_color, print_red_color, print_yellow_color
from std.os import getenv
from std.ffi import OwnedDLHandle, c_int
from std.python import Python

# Pinning handler
struct Pinning:
    var enabled: Bool
    var core_ids: List[Int]
    var libFuncC: OwnedDLHandle
    var last_assigned_core: Int

    # constructor
    def __init__(out self, path_libFuncC: String) raises:
        self.enabled = False
        self.core_ids = List[Int]()
        self.libFuncC = OwnedDLHandle(path_libFuncC)
        if not self.libFuncC.check_symbol("pin_thread_to_cpu"):
            raise "symbol pin_thread_to_cpu not found in libFuncC.so"
        self.last_assigned_core = 0

    # enable/disable pinning for the pipeline threads
    def setPinning(mut self, enabled: Bool):
        self.enabled = enabled

    # initialize the list of core ids for pinning
    def init_cores_list(mut self, s: String, num_cores: Int) raises:
        if (s == ""):
            for i in range(0, num_cores):
                self.core_ids.append(i)
        else:
            try:
                # split the string by commas
                var parts = s.split(",")
                for part in parts:
                    self.core_ids.append(Int(part))
            except:
                raise "invalid core id format in MOSTREAM_PINNING"

    # get the next core_id (not thread safe!)
    def get_next_core_id(mut self) -> Int:
        if not self.enabled:
            return -1 # return -1 if pinning is disabled
        var core_id = self.core_ids[self.last_assigned_core]
        self.last_assigned_core = (self.last_assigned_core + 1) % len(self.core_ids)
        return core_id

    # pin the calling thread on core_id
    def pin_on_the_core(mut self, core_id: Int) -> Int:
        if not self.enabled:
            return -1 # return -1 if pinning is disabled
        var r = self.libFuncC.call["pin_thread_to_cpu", c_int](c_int(core_id))
        if (r != 0):
            print_yellow_color("{MoStream} Warning: failed to pin thread to CPU core" + String(core_id))
        return core_id # return the core id to which the thread was pinned

# Pipeline
struct Pipeline[*Ts: NodeTrait]:
    comptime N = len(Self.Ts)
    var nodes: Tuple[*Self.Ts]
    var queue_size: Int
    var pinning_handler: Pinning

    # constructor
    def __init__(out self, var nodes: Tuple[*Self.Ts]) raises:
        comptime assert Self.N > 1, "Pipeline must have at least 2 stages!"
        comptime for i in range(Self.N):
            comptime assert Self.Ts[i].StageT.kind != StageKind.SOURCE or i == 0, "Source stage must be the first stage of the pipeline!"
            comptime assert Self.Ts[i].StageT.kind != StageKind.SINK or i == Self.N - 1, "Sink stage must be the last stage of the pipeline!"
        self.nodes = nodes^
        self.queue_size = 1024 # default size of the MPMC queues used for communication between stages
        var path_lib = getenv("MOSTREAM_HOME", ".")
        if path_lib == ".":
            print_yellow_color("{MoStream} Warning: MOSTREAM_HOME environment variable not set, using current directory as default")
        path_lib += "/MoStream/lib/libFuncC.so"
        self.pinning_handler = Pinning(path_lib)
        var mapping_str = getenv("MOSTREAM_PINNING", "")
        mp = Python.import_module("multiprocessing")
        self.pinning_handler.init_cores_list(mapping_str, Int(py=mp.cpu_count()))

    # _run_from
    def _run_from[idx: Int,
                 length: Int,
                 M: MessageTrait]
                 (mut self,
                 mut tg: TaskGroup,
                 in_comm: UnsafePointer[mut=True, Communicator[M], _]):    
        var np = self.nodes[idx].parallelism() # parallelism of node idx
        var nc = 0 # parallelism of the next node idx+1
        comptime if idx < Self.N-1:
            nc = self.nodes[idx+1].parallelism()
        out_comm = alloc[Communicator[Self.Ts[idx].StageT.OutType]](1)
        out_comm.init_pointee_move(Communicator[Self.Ts[idx].StageT.OutType](pN=np, cN=nc, queue_size=self.queue_size))
        for _ in range(0, np):
            tg.create_task(executor_task[idx, length](self.nodes[idx],
                                                      in_comm,
                                                      out_comm,
                                                      self.pinning_handler.get_next_core_id(),
                                                      self.pinning_handler))
        comptime if idx + 1 < Self.N:
            self._run_from[idx + 1, length, Self.Ts[idx].StageT.OutType](tg, out_comm)

    # run
    def run(mut self) raises:
        if (self.getNumNodes() > parallelism_level()):
            raise("the number of nodes in the pipeline is greater than the number threads available in the thread pool")
        var pinning = "disabled"
        if self.pinning_handler.enabled:
            pinning = "enabled"
        print_cyan_color("{MoStream} Starting pipeline execution with " + String(Self.N) + " stages and total parallelism of " + String(self.getNumNodes()) + " nodes")
        print_cyan_color("{MoStream} Standard MoStream runtime is used")
        print_cyan_color("{MoStream} CPU pinning is " + pinning)
        print_cyan_color("{MoStream} Pipeline starts...")
        var tg = TaskGroup()
        first_comm = alloc[Communicator[Self.Ts[0].StageT.InType]](1)
        first_comm.init_pointee_move(Communicator[Self.Ts[0].StageT.InType](pN=0, cN=self.nodes[0].parallelism(), queue_size=self.queue_size))
        self._run_from[0, Self.N](tg, first_comm)
        tg.wait()
        print_cyan_color("{MoStream} ...terminated successfully!")

    # _run_cooperative_from
    def _run_cooperative_from[idx: Int,
                             length: Int,
                             M: MessageTrait]
                             (mut self,
                             in_comm: UnsafePointer[mut=True, Communicator[M], _]):   
        var np = self.nodes[idx].parallelism() # parallelism of node idx
        var nc = 0 # parallelism of the next node idx+1
        comptime if idx < Self.N-1:
            nc = self.nodes[idx+1].parallelism()
        out_comm = alloc[Communicator[Self.Ts[idx].StageT.OutType]](1)
        out_comm.init_pointee_move(Communicator[Self.Ts[idx].StageT.OutType](pN=np, cN=nc, queue_size=self.queue_size))
        in_c = rebind[UnsafePointer[Communicator[Self.Ts[idx].StageT.InType], MutAnyOrigin]](in_comm)
        for _ in range(0, self.nodes[idx].parallelism()):
            self.nodes[idx].add_actor(Actor[Self.Ts[idx].StageT](stage=self.nodes[idx].make_stage(), in_comm=in_c, out_comm=out_comm))
        comptime if idx + 1 < Self.N:
            self._run_cooperative_from[idx + 1, length, Self.Ts[idx].StageT.OutType](out_comm)

    # run_cooperative
    def run_cooperative(mut self, n_workers: Int) raises:
        if (n_workers > parallelism_level()):
            raise("the number of workers of the cooperative scheduler is greater than the number threads available in the thread pool")
        var pinning = "disabled"
        if self.pinning_handler.enabled:
            pinning = "enabled"
        in_comm = alloc[Communicator[Self.Ts[0].StageT.InType]](1)
        in_comm.init_pointee_move(Communicator[Self.Ts[0].StageT.InType](pN=0, cN=self.nodes[0].parallelism(), queue_size=self.queue_size))
        out_comm = alloc[Communicator[Self.Ts[0].StageT.OutType]](1)
        out_comm.init_pointee_move(Communicator[Self.Ts[0].StageT.OutType](pN=self.nodes[0].parallelism(), cN=self.nodes[1].parallelism(), queue_size=self.queue_size))
        for _ in range(0, self.nodes[0].parallelism()):
            self.nodes[0].add_actor(Actor[Self.Ts[0].StageT](stage=self.nodes[0].make_stage(), in_comm=in_comm, out_comm=out_comm))
        self._run_cooperative_from[1, Self.N](out_comm)
        print_cyan_color("{MoStream} Starting pipeline execution with " + String(Self.N) + " stages and total parallelism of " + String(self.getNumNodes()) + " nodes")
        print_cyan_color("{MoStream} Cooperative MoStream runtime is used")
        print_cyan_color("{MoStream} CPU pinning is " + pinning)
        print_cyan_color("{MoStream} Pipeline starts...")
        var scheduler = Scheduler(self.nodes)
        scheduler.start(self.nodes, n_workers, self.pinning_handler)
        print_cyan_color("{MoStream} ...terminated successfully!")

    # enable/disable pinning for the pipeline threads
    def setPinning(mut self, enabled: Bool):
        self.pinning_handler.setPinning(enabled)

    # set the size of the queues used by the communicators between stages
    def setQueueSize(mut self, queue_size: Int):
        self.queue_size = queue_size

    # get number of nodes of this pipeline
    def getNumNodes(self) -> Int:
        var total_nodes = 0
        comptime for i in range(0, Self.N):
            total_nodes += self.nodes[i].parallelism()
        return total_nodes
