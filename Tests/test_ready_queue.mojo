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

from MoStream.ready_queue import (
    MPMCReadyQueues,
    ReadyQueueResult,
    StageMPMCReadyQueues,
    WorkStealingReadyQueues,
    ready_queue_capacity,
)
from std.testing import assert_equal, assert_true, TestSuite

# Tests for the ready queue implementations
def test_ready_queue_capacity_reserves_work_stealing_slot() raises:
    assert_equal(ready_queue_capacity(1), 2)
    assert_equal(ready_queue_capacity(2), 4)
    assert_equal(ready_queue_capacity(7), 8)
    assert_equal(ready_queue_capacity(8), 16)

# Tests for the MPMC and work-stealing backends
def test_mpmc_backend_uses_fifo_for_local_and_stolen_work() raises:
    var queues = MPMCReadyQueues(2, 8)
    assert_true(queues.push_local(0, 10))
    assert_true(queues.push_local(0, 20))
    assert_true(queues.push_local(0, 30))
    var local = queues.pop_local(0)
    assert_equal(local.status, ReadyQueueResult.SUCCESS)
    assert_equal(local.actor_id, Int64(10))
    var stolen = queues.steal_from(0)
    assert_equal(stolen.status, ReadyQueueResult.SUCCESS)
    assert_equal(stolen.actor_id, Int64(20))

# Tests for the work-stealing backend
def test_work_stealing_backend_uses_opposite_ends() raises:
    var queues = WorkStealingReadyQueues(2, 8)
    assert_true(queues.push_local(0, 10))
    assert_true(queues.push_local(0, 20))
    assert_true(queues.push_local(0, 30))
    var local = queues.pop_local(0)
    assert_equal(local.status, ReadyQueueResult.SUCCESS)
    assert_equal(local.actor_id, Int64(30))
    var stolen = queues.steal_from(0)
    assert_equal(stolen.status, ReadyQueueResult.SUCCESS)
    assert_equal(stolen.actor_id, Int64(10))

# Tests for the stage-based MPMC backend
def test_stage_mpmc_backend_tracks_eligible_stages() raises:
    var queues = StageMPMCReadyQueues(3, 8)
    assert_true(queues.push_stage(0, 10))
    assert_true(queues.push_stage(1, 20))
    assert_true(queues.push_stage(1, 30))
    assert_equal(queues.ready_count(0), Int64(1))
    assert_equal(queues.ready_count(1), Int64(2))
    assert_equal(queues.ready_count(2), Int64(0))
    var first = queues.pop_stage(1)
    assert_equal(first.status, ReadyQueueResult.SUCCESS)
    assert_equal(first.actor_id, Int64(20))
    assert_equal(queues.ready_count(1), Int64(1))
    var second = queues.pop_stage(1)
    assert_equal(second.status, ReadyQueueResult.SUCCESS)
    assert_equal(second.actor_id, Int64(30))
    assert_equal(queues.ready_count(1), Int64(0))

# Main
def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
