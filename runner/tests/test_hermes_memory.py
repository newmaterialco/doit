"""Tests for runner.hermes_memory.

These cover the on-disk format we share with Hermes' built-in memory
(MEMORY.md / USER.md): parsing, serialization, character-limit handling,
fingerprint stability, and the user-pin staging flow that the runner uses
before every /v1/runs call.

Pure stdlib — no Supabase / Hermes / network. Run with:

    python -m unittest discover -s runner/tests -v
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from runner.hermes_memory import (
    ENTRY_DELIMITER,
    HermesMemoryStore,
    MEMORY_CHAR_LIMIT,
    USER_CHAR_LIMIT,
    fingerprint,
)


class HermesMemoryStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.profiles_dir = Path(self._tmp.name)
        self.store = HermesMemoryStore(self.profiles_dir, "alice")

    # ------------------------------------------------------------------
    # Paths
    # ------------------------------------------------------------------

    def test_paths_are_per_profile(self) -> None:
        self.assertEqual(
            self.store.path_for("user"),
            self.profiles_dir / "alice" / "memories" / "USER.md",
        )
        self.assertEqual(
            self.store.path_for("memory"),
            self.profiles_dir / "alice" / "memories" / "MEMORY.md",
        )

    def test_limits_match_hermes_defaults(self) -> None:
        self.assertEqual(self.store.limit_for("user"), USER_CHAR_LIMIT)
        self.assertEqual(self.store.limit_for("memory"), MEMORY_CHAR_LIMIT)

    # ------------------------------------------------------------------
    # Read / write round trip
    # ------------------------------------------------------------------

    def test_missing_file_reads_empty(self) -> None:
        self.assertEqual(self.store.read_entries("user"), [])
        self.assertEqual(self.store.read_entries("memory"), [])

    def test_write_then_read_round_trips_entries(self) -> None:
        self.store.write_entries(
            "user",
            [
                "User prefers concise email replies.",
                "Personal email: gabe@example.com",
            ],
        )
        entries = self.store.read_entries("user")
        self.assertEqual(
            [e.text for e in entries],
            [
                "User prefers concise email replies.",
                "Personal email: gabe@example.com",
            ],
        )

    def test_disk_format_uses_section_sign_delimiter(self) -> None:
        self.store.write_entries("memory", ["a", "b"])
        raw = self.store.path_for("memory").read_text(encoding="utf-8")
        self.assertIn(ENTRY_DELIMITER, raw)
        # No extraneous delimiter at the start or trailing.
        self.assertFalse(raw.startswith(ENTRY_DELIMITER))
        self.assertEqual(raw.count(ENTRY_DELIMITER), 1)

    def test_blank_and_duplicate_entries_are_dropped(self) -> None:
        written = self.store.write_entries(
            "user",
            [" ", "fact one", "fact one", "Fact ONE", ""],
        )
        self.assertEqual(len(written), 1)
        self.assertEqual(written[0].text, "fact one")

    # ------------------------------------------------------------------
    # Character limits
    # ------------------------------------------------------------------

    def test_write_drops_from_tail_when_over_limit(self) -> None:
        big = "x" * (USER_CHAR_LIMIT // 2)
        # Three half-limit entries can't all fit in USER.md.
        written = self.store.write_entries("user", [big, big, big])
        self.assertLess(len(written), 3)
        size = self.store.path_for("user").stat().st_size
        self.assertLessEqual(size, USER_CHAR_LIMIT + 1)  # +newline

    # ------------------------------------------------------------------
    # Pin staging (Supabase -> Hermes)
    # ------------------------------------------------------------------

    def test_stage_preserves_existing_entries_and_adds_new(self) -> None:
        self.store.write_entries("user", ["existing fact"])
        written, skipped = self.store.stage_pinned_entries(
            "user", ["pinned by user"]
        )
        texts = [e.text for e in written]
        self.assertEqual(texts, ["existing fact", "pinned by user"])
        self.assertEqual(skipped, [])

    def test_stage_skips_pins_that_already_exist(self) -> None:
        self.store.write_entries("user", ["dup"])
        written, skipped = self.store.stage_pinned_entries("user", ["dup"])
        self.assertEqual([e.text for e in written], ["dup"])
        self.assertEqual(skipped, [])

    def test_stage_returns_skipped_when_file_is_full(self) -> None:
        big_existing = "x" * (USER_CHAR_LIMIT - 5)
        self.store.write_entries("user", [big_existing])
        too_big = "y" * 200
        _, skipped = self.store.stage_pinned_entries("user", [too_big])
        self.assertIn(too_big, skipped)

    # ------------------------------------------------------------------
    # Fingerprints
    # ------------------------------------------------------------------

    def test_fingerprint_is_stable_across_whitespace(self) -> None:
        a = fingerprint("Personal email: gabe@example.com")
        b = fingerprint("  personal email:    gabe@example.com  ")
        self.assertEqual(a, b)

    def test_fingerprint_differs_for_different_content(self) -> None:
        self.assertNotEqual(
            fingerprint("Personal email: gabe@example.com"),
            fingerprint("Personal email: somebodyelse@example.com"),
        )


if __name__ == "__main__":
    unittest.main()
