"""Parse Hermes-style schedule strings and compute next run times.

Supported formats (aligned with Hermes cron docs):
  - Relative delay: ``30m``, ``2h``, ``1d``
  - Interval: ``every 2h``, ``every 30m``, ``every 1d``
  - Cron expression: ``0 9 * * *`` (5-field, minute-first)
  - ISO timestamp: ``2025-01-15T09:00:00`` or with timezone
"""
from __future__ import annotations

import logging
import re
from datetime import UTC, datetime, timedelta
from typing import Literal

log = logging.getLogger(__name__)

ScheduleKind = Literal["delay", "interval", "cron", "once"]

_REL_DELAY = re.compile(r"^\s*(\d+)\s*([mhd])\s*$", re.IGNORECASE)
_INTERVAL = re.compile(
    r"^\s*every\s+(\d+)\s*([mhd])\s*$",
    re.IGNORECASE,
)
_CRON = re.compile(
    r"^\s*(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s*$",
)


def _unit_delta(value: int, unit: str) -> timedelta:
    u = unit.lower()
    if u == "m":
        return timedelta(minutes=value)
    if u == "h":
        return timedelta(hours=value)
    if u == "d":
        return timedelta(days=value)
    raise ValueError(f"unknown unit {unit!r}")


def classify_schedule(schedule: str) -> ScheduleKind | None:
    s = (schedule or "").strip()
    if not s:
        return None
    if _REL_DELAY.match(s):
        return "delay"
    if _INTERVAL.match(s):
        return "interval"
    if _CRON.match(s):
        return "cron"
    try:
        datetime.fromisoformat(s.replace("Z", "+00:00"))
        return "once"
    except ValueError:
        return None


def compute_next_run(
    schedule: str,
    *,
    from_time: datetime | None = None,
) -> datetime | None:
    """Return the next UTC run time for ``schedule``, or ``None`` if unknown."""
    s = (schedule or "").strip()
    if not s:
        return None
    now = from_time or datetime.now(UTC)
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)

    m = _REL_DELAY.match(s)
    if m:
        return now + _unit_delta(int(m.group(1)), m.group(2))

    m = _INTERVAL.match(s)
    if m:
        return now + _unit_delta(int(m.group(1)), m.group(2))

    try:
        iso = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if iso.tzinfo is None:
            iso = iso.replace(tzinfo=UTC)
        return iso if iso > now else None
    except ValueError:
        pass

    m = _CRON.match(s)
    if m:
        expr = m.group(1)
        try:
            from croniter import croniter

            base = now.replace(second=0, microsecond=0)
            itr = croniter(expr, base)
            nxt = itr.get_next(datetime)
            if nxt.tzinfo is None:
                nxt = nxt.replace(tzinfo=UTC)
            return nxt
        except Exception as e:
            log.warning("cron parse failed for %r: %s", expr, e)
            return None

    return None


def advance_next_run(
    schedule: str,
    *,
    after: datetime | None = None,
) -> datetime | None:
    """After a job fires, compute the following run time.

    One-shot schedules (relative delay or ISO timestamp) return ``None``
    so the caller can mark the job completed.
    """
    kind = classify_schedule(schedule)
    if kind in {"delay", "once"}:
        return None
    base = after or datetime.now(UTC)
    return compute_next_run(schedule, from_time=base + timedelta(seconds=1))
