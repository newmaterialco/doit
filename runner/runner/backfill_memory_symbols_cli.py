"""Backfill Passbook memory SF Symbol names for existing rows.

Usage::

    python -m runner.backfill_memory_symbols_cli
    python -m runner.backfill_memory_symbols_cli --user-id <uuid>
"""
from __future__ import annotations

import argparse
import logging
import sys

from .config import load as load_config
from .db import DB
from .memory_symbol import resolve_memory_symbol

log = logging.getLogger(__name__)


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Backfill memories.symbol_name for Passbook-visible rows."
    )
    parser.add_argument("--user-id", help="Limit to one user UUID")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    _setup_logging(args.verbose)

    cfg = load_config()
    db = DB(cfg)
    client = db._client

    query = (
        client.table("memories")
        .select("id, user_id, title, body, target, memory_status, symbol_name")
        .eq("target", "user")
        .in_("memory_status", ["active", "proposed"])
    )
    if args.user_id:
        query = query.eq("user_id", args.user_id)
    rows = query.execute().data or []

    updated = 0
    for row in rows:
        title = str(row.get("title") or "")
        body = str(row.get("body") or "")
        symbol = resolve_memory_symbol(
            symbol_name=row.get("symbol_name"),
            title=title,
            body=body,
        )
        if row.get("symbol_name") == symbol:
            continue
        client.table("memories").update({"symbol_name": symbol}).eq(
            "id", row["id"]
        ).execute()
        updated += 1
        log.info("symbol %s -> %r (%r)", row["id"], symbol, title[:60])

    log.info("backfilled %d/%d passbook-visible memories", updated, len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
