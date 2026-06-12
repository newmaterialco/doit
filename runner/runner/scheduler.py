"""Concurrency primitives for the runner's worker pool.

The main loop claims work items (prep passes, cron jobs, todos) and spawns
each one as an asyncio task. Two structures keep that safe:

``TaskPool``
    Bounds how many work items run at once (``MAX_CONCURRENT_RUNS``). The
    loop only claims new work while the pool has a free slot, so claimed
    rows never pile up in-process waiting for capacity.

``UserGates``
    Per-user coordination. Hermes runs for one user may overlap (that is
    the point of the pool), but three things must stay serialized or
    deferred per user:

    * **Staging lock** — the runner rewrites the profile's memory files
      (``memories/USER.md`` / ``MEMORY.md``), edits ``config.yaml`` /
      ``.env``, and mirrors memory back after runs. Those read-modify-write
      file operations hold ``gate.staging`` so two overlapping runs can't
      interleave writes.
    * **Restart safety** — applying a model setting or installing a
      browse.sh skill restarts the user's Hermes gateway, which would kill
      any other in-flight run on that profile. ``gate.restart_safe`` is
      only true while the current work item is the user's sole active one;
      callers skip/defer the restart otherwise.
    * **Execution cap** — ``MAX_RUNS_PER_USER`` keeps one user from
      occupying the whole pool. The loop excludes capped users at claim
      time so their queued todos simply stay ``requested`` until a slot
      frees up.
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Awaitable

log = logging.getLogger(__name__)


@dataclass
class UserGate:
    """Mutable per-user coordination state. Single event loop only."""

    user_id: str
    # Held around profile-file critical sections (memory staging/mirror,
    # config edits). NOT held for the long SSE-consumption middle of a run.
    staging: asyncio.Lock = field(default_factory=asyncio.Lock)
    # All in-flight work items for this user (todos + cron runs + preps).
    active_total: int = 0
    # Execution-class work only (todos + cron runs); preps and cron
    # configure passes are short and don't count against the user cap.
    active_exec: int = 0

    @property
    def restart_safe(self) -> bool:
        """True when restarting this user's Hermes gateway kills nothing else.

        The caller's own work item is expected to already be registered, so
        "safe" means it is the only one.
        """
        return self.active_total <= 1


class UserGates:
    """Registry of ``UserGate`` objects, created on demand."""

    def __init__(self) -> None:
        self._gates: dict[str, UserGate] = {}

    def get(self, user_id: str) -> UserGate:
        gate = self._gates.get(user_id)
        if gate is None:
            gate = UserGate(user_id=user_id)
            self._gates[user_id] = gate
        return gate

    def release_if_idle(self, user_id: str) -> None:
        gate = self._gates.get(user_id)
        if gate is not None and gate.active_total <= 0 and not gate.staging.locked():
            del self._gates[user_id]

    def users_at_exec_cap(self, max_runs_per_user: int) -> list[str]:
        if max_runs_per_user <= 0:
            return []
        return [
            user_id
            for user_id, gate in self._gates.items()
            if gate.active_exec >= max_runs_per_user
        ]


class TaskPool:
    """Bounded set of in-flight asyncio tasks for claimed work items."""

    def __init__(self, max_concurrent: int) -> None:
        self._max = max(1, int(max_concurrent))
        self._tasks: set[asyncio.Task] = set()

    @property
    def active_count(self) -> int:
        return len(self._tasks)

    @property
    def has_capacity(self) -> bool:
        return len(self._tasks) < self._max

    def spawn(self, coro: Awaitable[None], *, name: str) -> asyncio.Task:
        task = asyncio.ensure_future(coro)
        task.set_name(name)
        self._tasks.add(task)
        task.add_done_callback(self._on_done)
        return task

    def _on_done(self, task: asyncio.Task) -> None:
        self._tasks.discard(task)
        if task.cancelled():
            return
        exc = task.exception()
        if exc is not None:
            # Work-item wrappers catch their own exceptions; anything that
            # reaches here is a bug, but it must never kill the pool.
            log.error("pool task %s crashed: %s", task.get_name(), exc, exc_info=exc)

    async def wait_for_capacity(self, timeout: float) -> None:
        """Block until any task finishes or ``timeout`` elapses."""
        if not self._tasks:
            return
        with_timeout = max(0.1, float(timeout))
        await asyncio.wait(
            set(self._tasks),
            timeout=with_timeout,
            return_when=asyncio.FIRST_COMPLETED,
        )

    async def drain(self) -> None:
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
