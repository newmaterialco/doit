"""Tests for runner.schedule."""
from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta

from runner.schedule import (
    advance_next_run,
    classify_schedule,
    compute_next_run,
)


class ScheduleTests(unittest.TestCase):
    def test_classify_relative_delay(self) -> None:
        self.assertEqual(classify_schedule("30m"), "delay")

    def test_classify_interval(self) -> None:
        self.assertEqual(classify_schedule("every 2h"), "interval")

    def test_classify_cron(self) -> None:
        self.assertEqual(classify_schedule("0 9 * * *"), "cron")

    def test_compute_relative_delay(self) -> None:
        base = datetime(2025, 1, 1, 12, 0, tzinfo=UTC)
        nxt = compute_next_run("30m", from_time=base)
        assert nxt is not None
        self.assertEqual(nxt, base + timedelta(minutes=30))

    def test_compute_interval(self) -> None:
        base = datetime(2025, 1, 1, 12, 0, tzinfo=UTC)
        nxt = compute_next_run("every 2h", from_time=base)
        assert nxt is not None
        self.assertEqual(nxt, base + timedelta(hours=2))

    def test_advance_one_shot_returns_none(self) -> None:
        after = datetime(2025, 1, 1, 12, 0, tzinfo=UTC)
        self.assertIsNone(advance_next_run("30m", after=after))

    def test_advance_interval_returns_next(self) -> None:
        after = datetime(2025, 1, 1, 12, 0, tzinfo=UTC)
        nxt = advance_next_run("every 2h", after=after)
        assert nxt is not None
        self.assertGreater(nxt, after)


if __name__ == "__main__":
    unittest.main()
