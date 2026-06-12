from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from runner.hermes_memory import HermesMemoryStore, LEGACY_USER_CHAR_LIMIT, serialized_size
from runner.memory_consolidate import consolidate_entries, consolidate_if_near_cap


class MemoryConsolidateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.store = HermesMemoryStore(
            Path(self._tmp.name),
            "alice",
            user_char_limit=LEGACY_USER_CHAR_LIMIT,
            memory_char_limit=LEGACY_USER_CHAR_LIMIT,
        )

    def test_consolidate_merges_near_duplicates(self) -> None:
        self.store.write_entries(
            "user",
            [
                "San Francisco address: User currently lives at 123 Market Street in San Francisco.",
                "Current San Francisco address: User's current address is 123 Market St, San Francisco.",
                "Unrelated fact about coffee.",
            ],
        )
        entries = self.store.read_entries("user")
        kept, dropped, freed = consolidate_entries(entries)
        self.assertGreaterEqual(dropped, 1)
        self.assertGreater(freed, 0)
        self.assertEqual(len(kept), len(entries) - dropped)

    def test_consolidate_if_near_cap_rewrites_file(self) -> None:
        dup_a = "San Francisco address: User currently lives at 123 Market Street in San Francisco."
        dup_b = "Current San Francisco address: User's current address is 123 Market St, San Francisco."
        filler = "filler " * 130
        self.store.write_entries("user", [filler, dup_a, dup_b])
        limit = self.store.limit_for("user")
        self.assertGreater(serialized_size(self.store.read_entries("user")), limit * 0.5)
        changed = consolidate_if_near_cap(
            self.store,
            "user",
            user_id="u1",
            threshold_ratio=0.5,
        )
        self.assertTrue(changed)
        self.assertLess(len(self.store.read_entries("user")), 3)


if __name__ == "__main__":
    unittest.main()
