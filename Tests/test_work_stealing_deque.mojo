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

from MoStream.work_stealing_deque import (
    PaddedAtomicI64,
    WorkStealingDeque,
    WorkStealResult,
)
from std.atomic import Atomic, Ordering
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.runtime.asyncrt import TaskGroup
from std.sys.info import size_of
from std.testing import assert_equal, assert_false, assert_true, TestSuite


# record that an actor has seen and claimed a work item
def record_actor(
    actor_id: Int64,
    seen: Pointer[Atomic[DType.int64], MutUntrackedOrigin],
    claimed: Pointer[Atomic[DType.int64], MutUntrackedOrigin],
):
    _ = seen.unsafe_offset(Int(actor_id))[].fetch_add[
        ordering=Ordering.RELAXED
    ](1)
    _ = claimed[].fetch_add[ordering=Ordering.RELAXED](1)


# steal work items from the deque until it is empty
async def steal_until_empty(
    mut deque: WorkStealingDeque,
    seen: Pointer[Atomic[DType.int64], MutUntrackedOrigin],
    claimed: Pointer[Atomic[DType.int64], MutUntrackedOrigin],
):
    while True:
        var result = deque.steal_top()
        if result.status == WorkStealResult.SUCCESS:
            record_actor(result.actor_id, seen, claimed)
        elif result.status == WorkStealResult.EMPTY:
            return


# test that the owner pops items in LIFO order
def test_owner_lifo_order() raises:
    var deque = WorkStealingDeque(8)
    assert_true(deque.push_bottom(10))
    assert_true(deque.push_bottom(20))
    assert_true(deque.push_bottom(30))
    var result = deque.pop_bottom()
    assert_equal(result.status, WorkStealResult.SUCCESS)
    assert_equal(result.actor_id, Int64(30))
    result = deque.pop_bottom()
    assert_equal(result.actor_id, Int64(20))
    result = deque.pop_bottom()
    assert_equal(result.actor_id, Int64(10))
    assert_equal(deque.pop_bottom().status, WorkStealResult.EMPTY)


# test that thieves steal items in FIFO order
def test_thief_fifo_order() raises:
    var deque = WorkStealingDeque(8)
    assert_true(deque.push_bottom(10))
    assert_true(deque.push_bottom(20))
    assert_true(deque.push_bottom(30))
    var result = deque.steal_top()
    assert_equal(result.status, WorkStealResult.SUCCESS)
    assert_equal(result.actor_id, Int64(10))
    result = deque.steal_top()
    assert_equal(result.actor_id, Int64(20))
    result = deque.steal_top()
    assert_equal(result.actor_id, Int64(30))
    assert_equal(deque.steal_top().status, WorkStealResult.EMPTY)


# test that the owner and a thief can pop and steal from opposite ends of the deque
def test_owner_and_thief_opposite_ends() raises:
    var deque = WorkStealingDeque(8)
    assert_true(deque.push_bottom(1))
    assert_true(deque.push_bottom(2))
    assert_true(deque.push_bottom(3))
    var stolen = deque.steal_top()
    var local = deque.pop_bottom()
    assert_equal(stolen.actor_id, Int64(1))
    assert_equal(local.actor_id, Int64(3))
    assert_equal(deque.pop_bottom().actor_id, Int64(2))
    assert_equal(deque.size(), 0)


#  test that the owner cannot push more items than the capacity of the deque
def test_fixed_capacity_leaves_one_slot_unused() raises:
    var deque = WorkStealingDeque(4)
    assert_true(deque.push_bottom(1))
    assert_true(deque.push_bottom(2))
    assert_true(deque.push_bottom(3))
    assert_false(deque.push_bottom(4))


# test that the owner and multiple thieves can claim each actor exactly once
def test_indexes_are_cache_line_spaced() raises:
    assert_equal(size_of[PaddedAtomicI64](), 64)


# test that the owner and multiple thieves can claim each actor exactly once
def test_owner_and_multiple_thieves_claim_each_actor_once() raises:
    comptime ACTOR_COUNT = 1024
    comptime THIEF_COUNT = 4
    var deque = WorkStealingDeque(2048)
    var seen = unsafe_alloc[Atomic[DType.int64]](ACTOR_COUNT)
    var claimed = unsafe_alloc[Atomic[DType.int64]](1)
    claimed[] = Atomic[DType.int64](0)
    for actor_id in range(ACTOR_COUNT):
        seen.unsafe_offset(actor_id)[] = Atomic[DType.int64](0)
        assert_true(deque.push_bottom(Int64(actor_id)))
    var task_group = TaskGroup()
    for _ in range(THIEF_COUNT):
        var task = steal_until_empty(deque, seen, claimed)
        task_group.create_task(task^)
    while True:
        var result = deque.pop_bottom()
        if result.status != WorkStealResult.SUCCESS:
            break
        record_actor(result.actor_id, seen, claimed)
    task_group.wait()
    assert_equal(
        claimed[].load[ordering=Ordering.RELAXED](), Int64(ACTOR_COUNT)
    )
    for actor_id in range(ACTOR_COUNT):
        assert_equal(
            seen.unsafe_offset(actor_id)[].load[ordering=Ordering.RELAXED](),
            Int64(1),
        )
        seen.unsafe_offset(actor_id).unsafe_deinit_pointee()
    claimed.unsafe_deinit_pointee()
    claimed.unsafe_free()
    seen.unsafe_free()


# main
def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
