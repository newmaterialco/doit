"""Near-cap consolidation for Hermes on-disk memory files."""
from __future__ import annotations

import logging

from .hermes_memory import (
    HermesMemoryStore,
    MemoryEntry,
    MemoryTarget,
    serialized_size,
)
from .memory_dedupe import memory_similarity_score

log = logging.getLogger(__name__)

_DEFAULT_THRESHOLD = 0.85
_SIMILARITY_THRESHOLD = 0.62


def _entry_as_row(entry: MemoryEntry) -> dict:
    return {"title": "", "body": entry.text}


def _pick_survivor(
    a: MemoryEntry,
    a_idx: int,
    b: MemoryEntry,
    b_idx: int,
) -> int:
    """Keep the longer entry; tie-break toward the newer (higher index)."""
    if len(a.text) != len(b.text):
        return a_idx if len(a.text) > len(b.text) else b_idx
    return max(a_idx, b_idx)


def consolidate_entries(entries: list[MemoryEntry]) -> tuple[list[MemoryEntry], int, int]:
    """Merge near-duplicate clusters; return (kept, dropped_count, chars_freed)."""
    if len(entries) < 2:
        return entries, 0, 0

    before_size = serialized_size(entries)
    drop: set[int] = set()
    for i in range(len(entries)):
        if i in drop:
            continue
        for j in range(i + 1, len(entries)):
            if j in drop:
                continue
            score = memory_similarity_score(_entry_as_row(entries[i]), _entry_as_row(entries[j]))
            if score >= _SIMILARITY_THRESHOLD:
                survivor = _pick_survivor(entries[i], i, entries[j], j)
                drop.add(i if survivor == j else j)

    kept = [entry for idx, entry in enumerate(entries) if idx not in drop]
    after_size = serialized_size(kept)
    return kept, len(drop), max(0, before_size - after_size)


def consolidate_if_near_cap(
    store: HermesMemoryStore,
    target: MemoryTarget,
    *,
    user_id: str,
    threshold_ratio: float = _DEFAULT_THRESHOLD,
) -> bool:
    """When a file is >= ``threshold_ratio`` full, merge near-duplicates in place.

    Returns True when entries were dropped and the file was rewritten.
    """
    entries = store.read_entries(target)
    if len(entries) < 2:
        return False

    limit = store.limit_for(target)
    size = serialized_size(entries)
    if size < limit * threshold_ratio:
        return False

    consolidated, dropped, freed = consolidate_entries(entries)
    if dropped <= 0:
        return False

    store.write_entries(target, [entry.text for entry in consolidated])
    log.info(
        "memory consolidate user=%s target=%s dropped=%d freed=%d chars",
        user_id,
        target,
        dropped,
        freed,
    )
    return True
