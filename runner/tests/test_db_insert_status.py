"""Status routing on the runner's prepared-todo / spawned-todo inserts.

These tests pin two contracts:

* ``insert_prepared_todo(status=...)`` honours the caller's status, which
  the prep pipeline uses to insert auto-run extras alongside the original
  `+` sheet submission.
* ``insert_spawned_todo`` defaults to ``status='todo'`` so agent-spawned
  and cron-spawned tasks keep waiting for the user to tap Do it,
  preserving the existing UX.

We swap the DB's Supabase client out for a tiny fake so we can capture
the exact row payload without touching the network.
"""
from __future__ import annotations

import unittest
from typing import Any

from runner.db import DB


class _FakeExec:
    """Minimal stand-in for postgrest's `.execute()` response."""

    def __init__(self, data: list[dict[str, Any]]) -> None:
        self.data = data


class _FakeInsert:
    def __init__(self, recorder: dict[str, Any]) -> None:
        self._recorder = recorder

    def execute(self) -> _FakeExec:
        # Return a single row echoing the inserted payload so the caller's
        # `rows[0]` lookup works.
        return _FakeExec([dict(self._recorder["row"])])


class _FakeTable:
    def __init__(self, recorder: dict[str, Any]) -> None:
        self._recorder = recorder

    def insert(self, row: dict[str, Any]) -> _FakeInsert:
        self._recorder["row"] = dict(row)
        return _FakeInsert(self._recorder)


class _FakeClient:
    def __init__(self, recorder: dict[str, Any]) -> None:
        self._recorder = recorder

    def table(self, name: str) -> _FakeTable:
        self._recorder["table"] = name
        return _FakeTable(self._recorder)


def _make_db() -> tuple[DB, dict[str, Any]]:
    db = DB.__new__(DB)
    recorder: dict[str, Any] = {}
    db._client = _FakeClient(recorder)  # type: ignore[attr-defined]
    return db, recorder


class InsertPreparedTodoStatusTests(unittest.TestCase):
    def test_prepared_split_writes_requested(self) -> None:
        # The `+` sheet prep pass calls insert_prepared_todo with
        # status='requested' for each extra task in a multi-task split,
        # so the auto-run UX is consistent across all rows the user
        # implicitly created in one submission.
        db, recorder = _make_db()
        db.insert_prepared_todo(
            user_id="u1",
            title="Book calendar hold",
            original_title="Book calendar hold",
            connection_slug="googlecalendar",
            preparation_summary="Block time to review lease.",
            status="requested",
        )
        self.assertEqual(recorder["table"], "todos")
        self.assertEqual(recorder["row"]["status"], "requested")
        self.assertEqual(recorder["row"]["title"], "Book calendar hold")
        self.assertEqual(recorder["row"]["connection_slug"], "googlecalendar")

    def test_prepared_default_status_is_todo(self) -> None:
        # Older callers that don't opt into auto-run should still land
        # at status='todo' so legacy behaviour stays intact.
        db, recorder = _make_db()
        db.insert_prepared_todo(
            user_id="u1",
            title="Read the lease",
            original_title="Read the lease",
        )
        self.assertEqual(recorder["row"]["status"], "todo")


class InsertSpawnedTodoStatusTests(unittest.TestCase):
    def test_default_status_is_todo(self) -> None:
        # Agent / cron spawned tasks must continue to wait for the user
        # to tap Do it. Auto-run is reserved for the `+` sheet submission.
        db, recorder = _make_db()
        db.insert_spawned_todo(
            user_id="u1",
            title="Reply to Alex",
            original_title="Reply to Alex",
            spawn_key="gmail:msg:1",
            spawned_by_cron_job_id="cron-1",
        )
        self.assertEqual(recorder["row"]["status"], "todo")
        self.assertEqual(recorder["row"]["spawned_by_cron_job_id"], "cron-1")
        self.assertEqual(recorder["row"]["spawn_key"], "gmail:msg:1")

    def test_explicit_status_is_honored(self) -> None:
        # The status parameter is the single knob — if a future caller
        # wants to opt a spawned row into auto-run it stays a one-line
        # change here rather than another insert helper.
        db, recorder = _make_db()
        db.insert_spawned_todo(
            user_id="u1",
            title="Draft summary",
            original_title="Draft summary",
            status="requested",
        )
        self.assertEqual(recorder["row"]["status"], "requested")


if __name__ == "__main__":
    unittest.main()
