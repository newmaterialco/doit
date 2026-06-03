"""Backfill Settings > Memory from what Hermes already remembers.

The runner mirrors USER.md / MEMORY.md back to Supabase after every todo
finishes, so under normal operation Settings > Memory stays in sync. This
CLI exists for the cases where that loop hasn't run yet:

  * a user has been chatting with their Hermes profile for a while and
    Settings > Memory still looks empty,
  * we just shipped the mirror code and want to populate existing rows,
  * we want a one-shot diagnostic to confirm Hermes actually saved
    something after the personal-email test in DEMO.md.

Usage::

    python -m runner.mirror_memory_cli --user-id <uuid>
    python -m runner.mirror_memory_cli --all
    python -m runner.mirror_memory_cli --profile gabe   # by profile name

Reads ``HERMES_PROFILES_DIR`` (default ``~/.hermes/profiles``) and the
usual ``SUPABASE_URL`` / ``SUPABASE_SERVICE_ROLE_KEY`` env vars from
:mod:`runner.config`. Intentionally a small standalone entry point so it
can be wired into a one-off SSH-to-the-VM workflow without dragging in
the full poll loop.
"""
from __future__ import annotations

import argparse
import logging
import sys

from .config import load as load_config
from .db import DB
from .hermes_memory import HermesMemoryStore
from .runner import _mirror_hermes_memory_to_supabase

log = logging.getLogger(__name__)


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def _mirror_one(
    cfg, db: DB, *, user_id: str, profile_name: str
) -> tuple[int, int]:
    """Mirror one user's Hermes memory files and return (user_rows, memory_rows)."""
    store = HermesMemoryStore(cfg.hermes_profiles_dir, profile_name)
    user_path = store.path_for("user")
    mem_path = store.path_for("memory")
    if not user_path.exists() and not mem_path.exists():
        log.warning(
            "no memory files for profile %s (looked at %s and %s); "
            "is this user provisioned and has Hermes ever run for them?",
            profile_name,
            user_path,
            mem_path,
        )
        return (0, 0)

    user_entries = store.read_entries("user") if user_path.exists() else []
    mem_entries = store.read_entries("memory") if mem_path.exists() else []
    _mirror_hermes_memory_to_supabase(db, store, user_id)
    log.info(
        "mirrored %s: USER.md=%d entries, MEMORY.md=%d entries",
        profile_name,
        len(user_entries),
        len(mem_entries),
    )
    return (len(user_entries), len(mem_entries))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Mirror Hermes' USER.md / MEMORY.md into the Supabase `memories` "
            "table so Settings > Memory reflects what the agent has learned."
        ),
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--user-id", help="Mirror only this Doit user id.")
    group.add_argument(
        "--profile",
        help=(
            "Mirror the user mapped to this Hermes profile name. Resolved "
            "via the user_hermes table."
        ),
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Mirror every user with a row in user_hermes.",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Debug logging."
    )
    args = parser.parse_args(argv)

    _setup_logging(args.verbose)
    cfg = load_config()
    db = DB(cfg)

    targets: list[dict[str, str]] = []
    if args.all:
        targets = db.list_user_hermes_profiles()
        if not targets:
            log.error("no rows in user_hermes; nothing to mirror.")
            return 2
    elif args.user_id:
        endpoint = db.get_user_hermes(args.user_id)
        if endpoint is None:
            log.error("no user_hermes row for user %s", args.user_id)
            return 2
        targets = [{"user_id": args.user_id, "profile_name": endpoint.profile_name}]
    else:
        # --profile: linear scan since user_hermes has one row per user and
        # the table is small. Avoids a second DB method just for this CLI.
        matches = [
            row
            for row in db.list_user_hermes_profiles()
            if row["profile_name"] == args.profile
        ]
        if not matches:
            log.error("no user_hermes row with profile_name=%s", args.profile)
            return 2
        targets = matches

    total_users = 0
    total_user_entries = 0
    total_memory_entries = 0
    for row in targets:
        try:
            u, m = _mirror_one(
                cfg,
                db,
                user_id=row["user_id"],
                profile_name=row["profile_name"],
            )
        except Exception:
            log.exception(
                "mirror failed for user=%s profile=%s",
                row["user_id"],
                row["profile_name"],
            )
            continue
        total_users += 1
        total_user_entries += u
        total_memory_entries += m

    log.info(
        "done: mirrored %d user(s); USER.md entries=%d MEMORY.md entries=%d",
        total_users,
        total_user_entries,
        total_memory_entries,
    )
    return 0 if total_users > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
