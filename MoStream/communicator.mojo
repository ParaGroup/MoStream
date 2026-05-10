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
from std.atomic import Atomic, Ordering
from std.memory import Reference
from MoStream.utils import print_red_color

# Trait of messages that can be sent through the Communicator
comptime MessageTrait = Copyable & ImplicitlyDestructible

# Wrapper of messages to include an end-of-stream flag
struct MessageWrapper[T: MessageTrait](Copyable):
    var data: Optional[Self.T] # the actual message data within an Optional
    var eos: Bool # end of stream

    # constructor I
    def __init__(out self, var data: Self.T, eos: Bool):
        self.data = Optional(data^)
        self.eos = eos

    # constructor II
    def __init__(out self, eos: Bool):
        self.data = None
        self.eos = eos

# Communicator that uses a lock-free MPMC queue to send messages between threads
struct Communicator[T: MessageTrait](Movable):
    var queue: UnsafePointer[MPMCQueue[MessageWrapper[Self.T]], MutExternalOrigin]
    var prodNum: Int # number of producers
    var consNum: Int # number of consumers
    var destroyCount: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]
    var remainingProducers: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]
    var closed: UnsafePointer[Atomic[DType.int64], MutExternalOrigin]

    # constructor
    def __init__(out self, pN: Int, cN: Int, queue_size: Int) raises:
        self.queue = alloc[MPMCQueue[MessageWrapper[Self.T]]](1)
        self.queue.init_pointee_move(MPMCQueue[MessageWrapper[Self.T]](size=queue_size))
        self.prodNum = pN
        self.consNum = cN
        self.destroyCount = alloc[Atomic[DType.int64]](1)
        self.destroyCount[] = Atomic[DType.int64](Int64(cN))
        self.remainingProducers = alloc[Atomic[DType.int64]](1)
        self.remainingProducers[] = Atomic[DType.int64](Int64(pN))
        self.closed = alloc[Atomic[DType.int64]](1)
        var initially_closed = Int64(0)
        if pN == 0:
            initially_closed = Int64(1)
        self.closed[] = Atomic[DType.int64](initially_closed)

    # move constructor
    def __init__(out self, *, deinit take: Self):
        self.queue = take.queue
        self.prodNum = take.prodNum
        self.consNum = take.consNum
        self.destroyCount = take.destroyCount
        self.remainingProducers = take.remainingProducers
        self.closed = take.closed

    # destructor
    def __del__(deinit self):
        self.queue.destroy_pointee()
        self.queue.free()
        self.destroyCount.destroy_pointee()
        self.destroyCount.free()
        self.remainingProducers.destroy_pointee()
        self.remainingProducers.free()
        self.closed.destroy_pointee()
        self.closed.free()

    # check if the communicator is closed (i.e., no more messages will be sent)
    def is_closed(mut self) -> Bool:
        return self.closed[].load[ordering=Ordering.ACQUIRE]() == Int64(1)

    # signaling that a producer has finished sending messages (to coordinate the sending of end-of-stream messages)
    def producer_finished(mut self):
        old_count = self.remainingProducers[].fetch_sub[ordering=Ordering.ACQUIRE_RELEASE](1)
        if old_count == Int64(1):
            Atomic[DType.int64].store[ordering=Ordering.RELEASE](UnsafePointer(to=self.closed[].value), Int64(1))

    # check whether the Communicator can be safely destroyed
    def check_isDestroyable(mut self) -> Bool:
        old_count = self.destroyCount[].fetch_sub[ordering=Ordering.ACQUIRE_RELEASE](1)
        return old_count == Int64(1)

    # push (continuous retry until a message has been successfully pushed)
    def push(mut self, var msg: MessageWrapper[Self.T]):
        _ = self.queue[].push(msg^)

    # try_push (returns None if the message has been successfully pushed, or the message itself if the queue is currently full)
    def try_push(mut self, var msg: MessageWrapper[Self.T]) -> Optional[MessageWrapper[Self.T]]:
        return self.queue[].try_push(msg^)

    # pop (continuous retry until a message is available)
    def pop(mut self) -> MessageWrapper[Self.T]:
        while True:
            var maybe_msg = self.try_pop()
            if maybe_msg:
                return maybe_msg.take()

    # try_pop (returns None when no message is currently available)
    def try_pop(mut self) -> Optional[MessageWrapper[Self.T]]:
        # first try_pop
        var maybe_msg = self.queue[].try_pop()
        if maybe_msg:
            return maybe_msg^

        # if the queue looked empty, check whether producers are finished
        if not self.is_closed():
            return None

        # critical recheck
        maybe_msg = self.queue[].try_pop()
        if maybe_msg:
            return maybe_msg^

        # closed and still empty after the synchronized recheck
        return Optional(MessageWrapper[Self.T](eos=True))
