"""Cron configuration claim lease edge cases."""
from __future__ import annotations

import unittest
import sys
import types
from datetime import datetime, timedelta, timezone

supabase_stub = types.ModuleType("supabase")
supabase_stub.Client = object
supabase_stub.create_client = lambda *args, **kwargs: object()
sys.modules.setdefault("supabase", supabase_stub)
sys.modules.setdefault("httpx", types.ModuleType("httpx"))
dotenv_stub = types.ModuleType("dotenv")
dotenv_stub.load_dotenv = lambda *args, **kwargs: None
sys.modules.setdefault("dotenv", dotenv_stub)

from runner.db import _cron_config_claimable

UTC = timezone.utc


class CronConfigClaimableTests(unittest.TestCase):
    def test_null_claim_is_claimable(self) -> None:
        stale_before = datetime(2026, 6, 17, 12, 0, tzinfo=UTC)
        self.assertTrue(
            _cron_config_claimable(
                {"configure_claimed_at": None, "updated_at": stale_before.isoformat()},
                stale_before,
            )
        )

    def test_stale_claim_is_claimable(self) -> None:
        stale_before = datetime(2026, 6, 17, 12, 0, tzinfo=UTC)
        self.assertTrue(
            _cron_config_claimable(
                {
                    "configure_claimed_at": (stale_before - timedelta(seconds=1)).isoformat(),
                    "updated_at": stale_before.isoformat(),
                },
                stale_before,
            )
        )

    def test_fresh_reconfigure_after_claim_is_claimable(self) -> None:
        stale_before = datetime(2026, 6, 17, 12, 0, tzinfo=UTC)
        claimed_at = datetime(2026, 6, 17, 12, 5, tzinfo=UTC)
        self.assertTrue(
            _cron_config_claimable(
                {
                    "configure_claimed_at": claimed_at.isoformat(),
                    "updated_at": (claimed_at + timedelta(seconds=2)).isoformat(),
                },
                stale_before,
            )
        )

    def test_own_fresh_claim_is_not_immediately_reclaimed(self) -> None:
        stale_before = datetime(2026, 6, 17, 12, 0, tzinfo=UTC)
        claimed_at = datetime(2026, 6, 17, 12, 5, tzinfo=UTC)
        self.assertFalse(
            _cron_config_claimable(
                {
                    "configure_claimed_at": claimed_at.isoformat(),
                    "updated_at": (claimed_at + timedelta(milliseconds=100)).isoformat(),
                },
                stale_before,
            )
        )


if __name__ == "__main__":
    unittest.main()
