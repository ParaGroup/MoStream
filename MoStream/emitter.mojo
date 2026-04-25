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

from MoStream.communicator import MessageTrait, MessageWrapper, Communicator

# Emitter, used by TRANSFORM_MANY stages to emit output elements for the current input element being processed
@fieldwise_init
struct Emitter[Out: MessageTrait]:
    var outComm: UnsafePointer[Communicator[Self.Out], MutAnyOrigin]

    # produce a new output element for the current input element being processed
    #   by a TRANSFORM_MANY stage, by pushing it to the output communicator
    def emit(mut self, var output: Self.Out):
        self.outComm[].push(MessageWrapper[Self.Out](data = output^, eos = False))
