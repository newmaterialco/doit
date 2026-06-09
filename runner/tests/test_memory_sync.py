from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Any

from runner.hermes_memory import HermesMemoryStore
from runner.memory_sync import sync_active_memories_to_hermes


class _FakeDB:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows
        self.synced: list[tuple[str, str]] = []
        self.failed: list[tuple[str, str]] = []

    def list_active_memories_for_sync(self, user_id: str) -> list[dict]:
        return [r for r in self.rows if r.get("user_id") == user_id and r.get("memory_status") == "active"]

    def mark_memory_synced(self, memory_id: str, *, fingerprint: str, when_iso: str) -> None:
        self.synced.append((memory_id, fingerprint))

    def mark_memory_sync_failed(self, memory_id: str, *, error: str) -> None:
        self.failed.append((memory_id, error))


class MemorySourceOfTruthSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = HermesMemoryStore(Path(self.tmp.name), "gabriel")

    def test_rewrites_hermes_files_from_active_rows(self) -> None:
        self.store.write_entries("user", ["stale fact"])
        db = _FakeDB(
            [
                {
                    "id": "m1",
                    "user_id": "u1",
                    "target": "user",
                    "title": "Preferred signoff",
                    "body": "User signs emails as Gabe.",
                    "memory_status": "active",
                    "sync_status": "pending",
                },
                {
                    "id": "m2",
                    "user_id": "u1",
                    "target": "memory",
                    "title": "Workflow",
                    "body": "Use Gmail for email tasks.",
                    "memory_status": "active",
                    "sync_status": "synced",
                },
                {
                    "id": "m3",
                    "user_id": "u1",
                    "target": "user",
                    "title": "Rejected",
                    "body": "Do not sync this.",
                    "memory_status": "rejected",
                    "sync_status": "pending",
                },
            ]
        )

        staged = sync_active_memories_to_hermes(db, self.store, "u1")

        user_entries = [e.text for e in self.store.read_entries("user")]
        memory_entries = [e.text for e in self.store.read_entries("memory")]
        self.assertEqual(user_entries, ["Preferred signoff: User signs emails as Gabe."])
        self.assertEqual(memory_entries, ["Workflow: Use Gmail for email tasks."])
        self.assertEqual([row["id"] for row in staged], ["m1"])
        self.assertEqual(len(db.synced), 2)
        self.assertEqual(db.failed, [])

    def test_empty_active_rows_clear_files(self) -> None:
        self.store.write_entries("user", ["old"])
        self.store.write_entries("memory", ["old memory"])
        db = _FakeDB([])

        sync_active_memories_to_hermes(db, self.store, "u1")

        self.assertEqual(self.store.read_entries("user"), [])
        self.assertEqual(self.store.read_entries("memory"), [])


if __name__ == "__main__":
    unittest.main()

