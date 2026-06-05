"""Tests for runner.schedule."""
from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

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


class CronTimezoneTests(unittest.TestCase):
    """Wall-clock cron expressions are evaluated in the job's timezone."""

    def test_legacy_utc_when_no_timezone(self) -> None:
        # Pre-timezone rows pass timezone=None and must keep the old
        # UTC-based behavior so an in-flight job doesn't silently shift.
        base = datetime(2025, 6, 1, 8, 0, tzinfo=UTC)
        nxt = compute_next_run("0 9 * * *", from_time=base)
        assert nxt is not None
        self.assertEqual(nxt, datetime(2025, 6, 1, 9, 0, tzinfo=UTC))

    def test_pacific_summer_dst(self) -> None:
        # 2025-06-01 is PDT (UTC-7). "9 AM Pacific daily" should fire at
        # 16:00 UTC, not 09:00 UTC.
        base = datetime(2025, 6, 1, 8, 0, tzinfo=UTC)
        nxt = compute_next_run(
            "0 9 * * *",
            from_time=base,
            timezone="America/Los_Angeles",
        )
        assert nxt is not None
        self.assertEqual(nxt, datetime(2025, 6, 1, 16, 0, tzinfo=UTC))

    def test_pacific_winter_standard_time(self) -> None:
        # 2025-01-15 is PST (UTC-8). Same wall-clock 9 AM resolves to 17:00 UTC.
        base = datetime(2025, 1, 15, 0, 0, tzinfo=UTC)
        nxt = compute_next_run(
            "0 9 * * *",
            from_time=base,
            timezone="America/Los_Angeles",
        )
        assert nxt is not None
        self.assertEqual(nxt, datetime(2025, 1, 15, 17, 0, tzinfo=UTC))

    def test_dst_spring_forward_keeps_local_time(self) -> None:
        # On 2025-03-09 PT springs forward at 02:00 → 03:00. A job firing
        # at 09:00 PT before and after should keep the same wall-clock
        # time, even though the UTC offset shifts from -8 to -7.
        before = datetime(2025, 3, 8, 17, 1, tzinfo=UTC)  # just past 9 AM PT
        nxt = compute_next_run(
            "0 9 * * *",
            from_time=before,
            timezone="America/Los_Angeles",
        )
        assert nxt is not None
        # Next fire is 2025-03-09 09:00 PDT == 16:00 UTC.
        self.assertEqual(nxt, datetime(2025, 3, 9, 16, 0, tzinfo=UTC))
        local = nxt.astimezone(ZoneInfo("America/Los_Angeles"))
        self.assertEqual(local.hour, 9)
        self.assertEqual(local.minute, 0)

    def test_unknown_timezone_falls_back_to_utc(self) -> None:
        base = datetime(2025, 6, 1, 8, 0, tzinfo=UTC)
        nxt = compute_next_run(
            "0 9 * * *",
            from_time=base,
            timezone="Not/AReal_Zone",
        )
        assert nxt is not None
        self.assertEqual(nxt, datetime(2025, 6, 1, 9, 0, tzinfo=UTC))

    def test_advance_threads_timezone(self) -> None:
        after = datetime(2025, 6, 1, 16, 0, tzinfo=UTC)  # just fired at 9 AM PT
        nxt = advance_next_run(
            "0 9 * * *",
            after=after,
            timezone="America/Los_Angeles",
        )
        assert nxt is not None
        self.assertEqual(nxt, datetime(2025, 6, 2, 16, 0, tzinfo=UTC))

    def test_interval_ignores_timezone(self) -> None:
        # Relative intervals are duration-based; timezone is irrelevant.
        base = datetime(2025, 6, 1, 12, 0, tzinfo=UTC)
        nxt = compute_next_run(
            "every 2h",
            from_time=base,
            timezone="America/Los_Angeles",
        )
        assert nxt is not None
        self.assertEqual(nxt, base + timedelta(hours=2))


if __name__ == "__main__":
    unittest.main()
