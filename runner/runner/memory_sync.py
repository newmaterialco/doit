"""Sync Doit's app memory rows with Hermes' built-in memory files."""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import TYPE_CHECKING

from .hermes_memory import HermesMemoryStore, MemoryTarget, fingerprint as memory_fingerprint

if TYPE_CHECKING:
    from .db import DB

log = logging.getLogger(__name__)


def sync_active_memories_to_hermes(
    db: "DB",
    store: HermesMemoryStore,
    user_id: str,
) -> list[dict]:
    """Rewrite Hermes memory files from active Supabase memory rows.

    Supabase is the product source of truth. Hermes' USER.md / MEMORY.md are a
    model-facing projection that gets rebuilt before runs. Returning only rows
    that were pending/failed before this sync lets the prompt builder nudge the
    task agent about newly-added user-visible memories without repeating every
    active memory on every task.
    """
    active = db.list_active_memories_for_sync(user_id)
    by_target: dict[MemoryTarget, list[dict]] = {"user": [], "memory": []}
    for row in active:
        target = row.get("target") or "user"
        if target not in by_target:
            target = "user"
        by_target[target].append(row)

    staged_for_prompt: list[dict] = []
    now = datetime.now(timezone.utc).isoformat()
    for target, rows in by_target.items():
        texts = [_memory_row_to_entry_text(row) for row in rows]
        try:
            written = store.write_entries(target, texts)
        except Exception as e:
            log.exception("memory rewrite to %s failed for user %s", target, user_id)
            for row in rows:
                db.mark_memory_sync_failed(row["id"], error=str(e))
            continue

        written_fps = {entry.fingerprint for entry in written}
        for row in rows:
            text = _memory_row_to_entry_text(row)
            fp = memory_fingerprint(text)
            if fp not in written_fps:
                db.mark_memory_sync_failed(
                    row["id"],
                    error=(
                        "Hermes memory is full; remove or shorten existing "
                        "entries before adding this one."
                    ),
                )
                continue
            was_unsynced = row.get("sync_status") in ("pending", "failed")
            db.mark_memory_synced(row["id"], fingerprint=fp, when_iso=now)
            if was_unsynced:
                staged_for_prompt.append(row)

    # Ensure an empty target still clears the corresponding Hermes file.
    for target, rows in by_target.items():
        if rows:
            continue
        try:
            store.write_entries(target, [])
        except Exception as e:
            log.warning("failed to clear empty %s memory for user %s: %s", target, user_id, e)

    return staged_for_prompt


def mirror_hermes_memory_to_supabase(
    db: "DB",
    store: HermesMemoryStore,
    user_id: str,
) -> None:
    """Reflect direct Hermes memory-tool writes back into Supabase.

    This keeps compatibility with Hermes' built-in ``memory`` tool. The next
    source-of-truth rewrite will preserve these rows only if they remain active
    in Supabase.
    """
    now = datetime.now(timezone.utc).isoformat()
    existing = db.list_synced_memories(user_id)
    existing_by_key: dict[tuple[str, str], dict] = {}
    for row in existing:
        fp = row.get("hermes_fingerprint")
        target = row.get("target")
        if not fp or target not in ("user", "memory"):
            continue
        existing_by_key[(target, fp)] = row

    seen_keys: set[tuple[str, str]] = set()
    for target in ("user", "memory"):
        try:
            entries = store.read_entries(target)  # type: ignore[arg-type]
        except Exception as e:
            log.warning("read hermes %s memory for user %s failed: %s", target, user_id, e)
            continue
        for entry in entries:
            key = (target, entry.fingerprint)
            seen_keys.add(key)
            if key in existing_by_key:
                continue
            db.upsert_hermes_memory(
                user_id=user_id,
                target=target,
                text=entry.text,
                fingerprint=entry.fingerprint,
                when_iso=now,
            )

    for key, row in existing_by_key.items():
        if key in seen_keys:
            continue
        if row.get("source") != "hermes":
            continue
        db.mark_memory_deleted(row["id"])


def _memory_row_to_entry_text(row: dict) -> str:
    title = (row.get("title") or "").strip()
    body = (row.get("body") or "").strip()
    if title and body and title != body:
        return f"{title}: {body}"
    return body or title

