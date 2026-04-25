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

from MoStream.MPMC_queue import MPMCQueue
from std.collections import Optional
from std.sys.info import size_of
from std.atomic import Atomic
from std.memory import Reference

# Trait of messages that can be sent through the Communicator
comptime MessageTrait = ImplicitlyCopyable & Writable

# Wrapper of messages to include an end-of-stream flag
struct MessageWrapper[T: MessageTrait](ImplicitlyCopyable, Defaultable):
    var data: Optional[Self.T] # the actual message data within an Optional
    var eos: Bool # end of stream

    # constructor I
    def __init__(out self):
        self.data = None
        self.eos = False

    # constructor II
    def __init__(out self, var data: Self.T, eos: Bool):
        self.data = Optional(data^)
        self.eos = eos

    # constructor III
    def __init__(out self, eos: Bool):
        self.data = None
        self.eos = eos

# Communicator that uses a lock-free MPMC queue to send messages between threads
struct Communicator[T: MessageTrait](Movable):
    var queue: UnsafePointer[MPMCQueue[MessageWrapper[Self.T]], MutExternalOrigin]
    var prodNum: Int # number of producers
    var consNum: Int # number of consumers
    var destroyCount: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]
    var finishedProducerCount: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]

    # constructor
    def __init__(out self, pN: Int, cN: Int, queue_size: Int):
        self.queue = alloc[MPMCQueue[MessageWrapper[Self.T]]](1)
        q = MPMCQueue[MessageWrapper[Self.T]](size=queue_size)
        self.queue.init_pointee_move(q^)
        self.prodNum = pN
        self.consNum = cN
        self.destroyCount = alloc[Atomic[DType.int64]](1)
        self.destroyCount[] = Atomic[DType.int64](Int64(cN))
        self.finishedProducerCount = alloc[Atomic[DType.int64]](1)
        self.finishedProducerCount[] = Atomic[DType.int64](Int64(pN))

    # destructor
    def __del__(deinit self):
        self.queue.destroy_pointee()
        self.queue.free()
        self.destroyCount.destroy_pointee()
        self.destroyCount.free()
        self.finishedProducerCount.destroy_pointee()
        self.finishedProducerCount.free()

    # move constructor
    def __init__(out self, *, deinit take: Self):
        self.queue = take.queue
        self.prodNum = take.prodNum
        self.consNum = take.consNum
        self.destroyCount = take.destroyCount
        self.finishedProducerCount = take.finishedProducerCount

    # signaling that a producer has finished sending messages (to coordinate the sending of end-of-stream messages)
    def producer_finished(mut self):
        old_count = self.finishedProducerCount[].fetch_sub(1)
        if old_count == 1: # this was the last producer to finish
            for _ in range(0, self.consNum):
                self.push(MessageWrapper[Self.T](eos = True))

    # check whether the Communicator can be safely destroyed
    def check_isDestroyable(mut self) -> Bool:
        old_count = self.destroyCount[].fetch_sub(1)
        if old_count == 1: # this was the last consumer to check for destroyability
            return True
        else:
            return False

    # pop (continuous retry until a message is available)
    def pop(mut self) -> MessageWrapper[Self.T]:
        while True:
            result = self.queue[].pop()
            if result:
                return result.take()

    # push (when it returns, the message has been successfully pushed into the queue) 
    def push(mut self, var msg: MessageWrapper[Self.T]):
        _ = self.queue[].push(msg^)
