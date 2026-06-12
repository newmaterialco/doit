"""Tests for the worker-pool concurrency primitives."""
from __future__ import annotations

import asyncio
import unittest

from runner.scheduler import TaskPool, UserGates


class UserGatesTests(unittest.TestCase):
    def test_gate_is_reused_per_user(self) -> None:
        gates = UserGates()
        a = gates.get("user-a")
        self.assertIs(a, gates.get("user-a"))
        self.assertIsNot(a, gates.get("user-b"))

    def test_restart_safe_only_when_sole_active(self) -> None:
        gates = UserGates()
        gate = gates.get("user-a")
        gate.active_total = 1
        self.assertTrue(gate.restart_safe)
        gate.active_total = 2
        self.assertFalse(gate.restart_safe)

    def test_users_at_exec_cap(self) -> None:
        gates = UserGates()
        a = gates.get("user-a")
        b = gates.get("user-b")
        a.active_exec = 2
        b.active_exec = 1
        self.assertEqual(gates.users_at_exec_cap(2), ["user-a"])
        self.assertEqual(gates.users_at_exec_cap(1), ["user-a", "user-b"])
        # A cap of zero (or negative) disables the limit entirely.
        self.assertEqual(gates.users_at_exec_cap(0), [])

    def test_release_if_idle_drops_only_idle_gates(self) -> None:
        gates = UserGates()
        gate = gates.get("user-a")
        gate.active_total = 1
        gates.release_if_idle("user-a")
        self.assertIs(gate, gates.get("user-a"))

        gate.active_total = 0
        gates.release_if_idle("user-a")
        self.assertIsNot(gate, gates.get("user-a"))


class TaskPoolTests(unittest.IsolatedAsyncioTestCase):
    async def test_capacity_bound(self) -> None:
        pool = TaskPool(2)
        release = asyncio.Event()

        async def work() -> None:
            await release.wait()

        pool.spawn(work(), name="one")
        pool.spawn(work(), name="two")
        self.assertFalse(pool.has_capacity)
        self.assertEqual(pool.active_count, 2)

        release.set()
        await pool.drain()
        self.assertTrue(pool.has_capacity)
        self.assertEqual(pool.active_count, 0)

    async def test_wait_for_capacity_returns_when_task_finishes(self) -> None:
        pool = TaskPool(1)
        release = asyncio.Event()

        async def work() -> None:
            await release.wait()

        pool.spawn(work(), name="one")
        asyncio.get_running_loop().call_later(0.01, release.set)
        await asyncio.wait_for(pool.wait_for_capacity(5.0), timeout=2.0)
        # Either the task already left the pool or it finishes imminently.
        await pool.drain()
        self.assertEqual(pool.active_count, 0)

    async def test_crashing_task_does_not_kill_pool(self) -> None:
        pool = TaskPool(2)

        async def boom() -> None:
            raise RuntimeError("kaboom")

        pool.spawn(boom(), name="boom")
        await pool.drain()
        self.assertEqual(pool.active_count, 0)
        self.assertTrue(pool.has_capacity)

    async def test_min_pool_size_is_one(self) -> None:
        pool = TaskPool(0)
        self.assertTrue(pool.has_capacity)

        async def work() -> None:
            pass

        pool.spawn(work(), name="one")
        self.assertFalse(pool.has_capacity)
        await pool.drain()


if __name__ == "__main__":
    unittest.main()
