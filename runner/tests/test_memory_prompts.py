from __future__ import annotations

import unittest
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]


class MemoryPromptTests(unittest.TestCase):
    def test_main_prompt_mentions_explicit_memory_and_settings(self) -> None:
        hermes_source = (_ROOT / "runner" / "hermes.py").read_text()
        self.assertIn("Explicit memory requests", hermes_source)
        self.assertIn("session_search", hermes_source)
        self.assertIn("Settings and Passbook", hermes_source)

    def test_cron_prompt_uses_memory_and_session_search(self) -> None:
        cron_source = (_ROOT / "runner" / "cron.py").read_text()
        self.assertIn("MEMORY", cron_source)
        self.assertIn("session_search", cron_source)
        self.assertIn("memory tool", cron_source)


if __name__ == "__main__":
    unittest.main()

