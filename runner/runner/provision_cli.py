"""One-off (re)provisioning for a single user — the manual repair path.

Replaces the old hand-run steps from hermes/setup.md step 5/6. Runs the
exact same idempotent pipeline as the automatic provisioner, so it is safe
to re-run against a half-provisioned or already-working user: existing
ports, API keys, and Composio sessions are reused, not rotated.

Usage (on the VM, from the runner directory with the venv active)::

    python -m runner.provision_cli --user-id <supabase-user-uuid>

Reads the same runner .env as the main loop (SUPABASE_*, COMPOSIO_API_KEY,
HERMES_*). Updates the user's `user_provisioning` row if one exists, but
does not require one — you can provision a user who never redeemed an
invite code.
"""
from __future__ import annotations

import argparse
import logging
import sys

from .config import load as load_config
from .db import DB
from .provision import provision_user

log = logging.getLogger(__name__)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Provision or repair one user's Hermes agent end to end.",
    )
    parser.add_argument("--user-id", required=True, help="Supabase user uuid.")
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Debug logging."
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    cfg = load_config()
    db = DB(cfg)
    user_id = args.user_id.strip()

    try:
        provision_user(cfg, db, user_id)
    except Exception as e:
        log.error("provisioning failed for %s: %s", user_id, e)
        db.update_user_provisioning(
            user_id, {"status": "failed", "error": str(e)[:500]}
        )
        return 1

    db.update_user_provisioning(user_id, {"status": "ready", "error": None})
    log.info("user %s provisioned and ready", user_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
