"""Re-queue memory rows that failed because Hermes files were full.

After raising char limits and fixing eviction priority, run once to clear
red Sync failed badges without user action::

    python -m runner.requeue_failed_memories_cli --all
    python -m runner.requeue_failed_memories_cli --user-id <uuid>
"""
from __future__ import annotations

import argparse
import logging
import sys

from .config import load as load_config
from .db import DB

log = logging.getLogger(__name__)


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Re-queue memories with sync_status=failed and a 'memory is full' "
            "error so the next todo run restages them under the new limits."
        ),
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--user-id", help="Re-queue only this Doit user id.")
    group.add_argument(
        "--all",
        action="store_true",
        help="Re-queue for every user with matching failed rows.",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Debug logging."
    )
    args = parser.parse_args(argv)

    _setup_logging(args.verbose)
    cfg = load_config()
    db = DB(cfg)

    count = db.requeue_failed_memory_full(
        user_id=None if args.all else args.user_id
    )
    if count <= 0:
        log.warning("no matching failed memory rows to re-queue")
        return 1
    log.info("re-queued %d memory row(s)", count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
