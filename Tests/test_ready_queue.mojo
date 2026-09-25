from MoStream.ready_queue import (
    MPMCReadyQueues,
    ReadyQueueResult,
    WorkStealingReadyQueues,
    ready_queue_capacity,
)
from std.testing import assert_equal, assert_true, TestSuite


def test_ready_queue_capacity_reserves_work_stealing_slot() raises:
    assert_equal(ready_queue_capacity(1), 2)
    assert_equal(ready_queue_capacity(2), 4)
    assert_equal(ready_queue_capacity(7), 8)
    assert_equal(ready_queue_capacity(8), 16)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
