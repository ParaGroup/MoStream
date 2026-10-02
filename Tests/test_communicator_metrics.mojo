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

from MoStream.communicator import Communicator, MessageWrapper
from std.testing import assert_equal, assert_true, TestSuite

# Tests for the Communicator class
def test_communicator_tracks_queue_occupancy() raises:
    var communicator = Communicator[Int](pN=1, cN=1, queue_size=4)
    assert_equal(communicator.current_size(), Int64(0))
    assert_equal(communicator.fill_ratio(), 0.0)
    var first = MessageWrapper[Int](data=1, eos=False)
    var second = MessageWrapper[Int](data=2, eos=False)
    assert_true(not communicator.try_push(first^))
    assert_true(not communicator.try_push(second^))
    assert_equal(communicator.current_size(), Int64(2))
    assert_equal(communicator.fill_ratio(), 0.5)
    assert_true(communicator.try_pop())
    assert_equal(communicator.current_size(), Int64(1))
    assert_equal(communicator.fill_ratio(), 0.25)

# Main
def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
