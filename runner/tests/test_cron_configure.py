"""Tests for runner.cron_configure."""
from __future__ import annotations

import unittest

from runner.cron_configure import CONFIG_CLOSE, CONFIG_OPEN, parse_cron_config


def wrap(json_body: str) -> str:
    return f"{CONFIG_OPEN}\n{json_body}\n{CONFIG_CLOSE}"


class ParseCronConfigTests(unittest.TestCase):
    def test_clarification_roundtrip(self) -> None:
        text = wrap(
            '{"name":"Daily digest","prompt":"Summarize newsletters",'
            '"schedule":"0 9 * * *","schedule_display":"Daily at 9:00 AM",'
            '"ready":false,"clarification":{'
            '"prompt":"Where should I send the digest?",'
            '"options":[{"id":"email","label":"Email","style":"primary"},'
            '{"id":"slack","label":"Slack","style":"secondary"}]}}'
        )
        result = parse_cron_config(text)
        assert result is not None
        self.assertTrue(result.needs_clarification)
        self.assertEqual(result.schedule_display, "Daily at 9:00 AM")


if __name__ == "__main__":
    unittest.main()
