"""Read/write Hermes' native per-profile memory files.

Hermes stores curated, bounded memory on disk per profile:

    ~/.hermes/profiles/<profile>/memories/USER.md
    ~/.hermes/profiles/<profile>/memories/MEMORY.md

Both files are entry lists separated by the section sign delimiter (``§``).
At session start Hermes loads them into the system prompt as a frozen
snapshot; the agent then curates them via the ``memory`` tool while running.

This module gives the runner a small, focused API to:

    * Read existing entries from either file.
    * Write entries back atomically, respecting Hermes' character limits.
    * Stage user-pinned facts from Supabase into the right file ahead of a
      run so they appear in Hermes' next frozen snapshot.

It does NOT try to be a memory provider; the agent still owns curation.
We only sync the small set of things the user explicitly pinned in the iOS
app, and we never delete agent-managed entries unless the file is over
capacity — then oldest unpinned / agent-authored entries go first.
"""
from __future__ import annotations

import hashlib
import logging
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Literal

log = logging.getLogger(__name__)

MemoryTarget = Literal["user", "memory"]

# Hermes' legacy built-in limits (pre-capacity fix). Tests that need a tiny
# cap pass these explicitly to ``HermesMemoryStore``.
LEGACY_USER_CHAR_LIMIT = 1375
LEGACY_MEMORY_CHAR_LIMIT = 2200

# Raised defaults — override via env / Config (see runner.config).
USER_CHAR_LIMIT = 4000
MEMORY_CHAR_LIMIT = 8000

# Hermes' on-disk format uses the section sign as the entry delimiter.
ENTRY_DELIMITER = "§"

_FILE_BY_TARGET: dict[MemoryTarget, str] = {
    "user": "USER.md",
    "memory": "MEMORY.md",
}


@dataclass(frozen=True)
class MemoryEntry:
    """One on-disk memory entry plus a stable fingerprint."""

    target: MemoryTarget
    text: str
    fingerprint: str

    @property
    def char_count(self) -> int:
        return len(self.text)


class HermesMemoryStore:
    """File-backed accessor for one Hermes profile's MEMORY/USER stores."""

    def __init__(
        self,
        profiles_dir: str | os.PathLike[str],
        profile_name: str,
        *,
        user_char_limit: int = USER_CHAR_LIMIT,
        memory_char_limit: int = MEMORY_CHAR_LIMIT,
    ) -> None:
        self._memories_dir = Path(profiles_dir).expanduser() / profile_name / "memories"
        self._limits: dict[MemoryTarget, int] = {
            "user": user_char_limit,
            "memory": memory_char_limit,
        }

    @property
    def memories_dir(self) -> Path:
        return self._memories_dir

    def path_for(self, target: MemoryTarget) -> Path:
        return self._memories_dir / _FILE_BY_TARGET[target]

    def limit_for(self, target: MemoryTarget) -> int:
        return self._limits[target]

    # ------------------------------------------------------------------
    # Read
    # ------------------------------------------------------------------

    def read_entries(self, target: MemoryTarget) -> list[MemoryEntry]:
        """Return the parsed entries for ``target``.

        Empty / missing files return ``[]``. Whitespace-only entries are
        dropped. Entry order on disk is preserved.
        """
        path = self.path_for(target)
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return []
        return _parse_entries(raw, target)

    # ------------------------------------------------------------------
    # Write
    # ------------------------------------------------------------------

    def write_entries(
        self,
        target: MemoryTarget,
        entries: Iterable[str],
        *,
        protected_fingerprints: frozenset[str] | None = None,
        evict_first_fingerprints: frozenset[str] | None = None,
    ) -> list[MemoryEntry]:
        """Replace the on-disk file with ``entries``.

        Whitespace-only entries are dropped. Duplicates (by fingerprint) are
        merged keeping the first occurrence. When the combined size exceeds
        the limit, oldest **evict-first** entries (typically agent-authored)
        are removed before any **protected** user-visible rows. Only when
        protected entries alone exceed the limit do we drop from the tail.

        Returns the entries actually written, in order.
        """
        normalized = _normalize_entry_list(target, entries)
        limit = self.limit_for(target)
        capped = _cap_with_eviction(
            normalized,
            limit,
            protected=protected_fingerprints or frozenset(),
            evict_first=evict_first_fingerprints or frozenset(),
        )
        _atomic_write(self.path_for(target), _serialize_entries(capped))
        return capped

    def stage_pinned_entries(
        self,
        target: MemoryTarget,
        pinned_texts: Iterable[str],
        *,
        protected_fingerprints: frozenset[str] | None = None,
    ) -> tuple[list[MemoryEntry], list[str]]:
        """Append user-pinned entries to ``target`` if they aren't already there.

        Existing on-disk entries are preserved unless the file is over
        capacity — then oldest entries that are **not** protected (new pins
        plus any caller-supplied pinned fingerprints) are evicted first.

        Returns ``(written_entries, skipped_pinned_texts)``.
        """
        existing = self.read_entries(target)
        existing_fps = {entry.fingerprint for entry in existing}
        new_entries: list[MemoryEntry] = []
        for raw in pinned_texts:
            text = _normalize_entry(raw)
            if not text:
                continue
            fp = fingerprint(text)
            if fp in existing_fps:
                continue
            existing_fps.add(fp)
            new_entries.append(MemoryEntry(target=target, text=text, fingerprint=fp))

        if not new_entries:
            return existing, []

        protected = frozenset(
            {entry.fingerprint for entry in new_entries}
            | set(protected_fingerprints or ())
        )
        limit = self.limit_for(target)
        combined = existing + new_entries
        capped = _cap_with_eviction(
            combined,
            limit,
            protected=protected,
            evict_first=frozenset(
                entry.fingerprint
                for entry in existing
                if entry.fingerprint not in protected
            ),
        )
        kept_fps = {entry.fingerprint for entry in capped}
        skipped = [entry.text for entry in new_entries if entry.fingerprint not in kept_fps]
        _atomic_write(self.path_for(target), _serialize_entries(capped))
        return capped, skipped


def memory_store_for_profile(
    profiles_dir: str | os.PathLike[str],
    profile_name: str,
    *,
    user_char_limit: int = USER_CHAR_LIMIT,
    memory_char_limit: int = MEMORY_CHAR_LIMIT,
) -> HermesMemoryStore:
    """Construct a store with explicit char limits (typically from Config)."""
    return HermesMemoryStore(
        profiles_dir,
        profile_name,
        user_char_limit=user_char_limit,
        memory_char_limit=memory_char_limit,
    )


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


def fingerprint(text: str) -> str:
    """Stable, normalized hash for an entry. Short for compact storage."""
    norm = _canonicalize(text)
    return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:32]


def serialized_size(entries: list[MemoryEntry]) -> int:
    """Character count of the on-disk serialization for ``entries``."""
    return len(_serialize_entries(entries))


def _canonicalize(text: str) -> str:
    """Reduce trivial whitespace differences so the same fact hashes alike."""
    collapsed = re.sub(r"\s+", " ", text).strip()
    return collapsed.lower()


def _normalize_entry(text: str) -> str:
    """Strip outer whitespace; reject empties. Internal whitespace stays."""
    if text is None:
        return ""
    return text.strip()


def _normalize_entry_list(
    target: MemoryTarget, entries: Iterable[str]
) -> list[MemoryEntry]:
    normalized: list[MemoryEntry] = []
    seen: set[str] = set()
    for raw in entries:
        text = _normalize_entry(raw)
        if not text:
            continue
        fp = fingerprint(text)
        if fp in seen:
            continue
        seen.add(fp)
        normalized.append(MemoryEntry(target=target, text=text, fingerprint=fp))
    return normalized


def _parse_entries(raw: str, target: MemoryTarget) -> list[MemoryEntry]:
    if not raw or not raw.strip():
        return []
    parts = raw.split(ENTRY_DELIMITER)
    entries: list[MemoryEntry] = []
    seen: set[str] = set()
    for part in parts:
        text = _normalize_entry(part)
        if not text:
            continue
        fp = fingerprint(text)
        if fp in seen:
            continue
        seen.add(fp)
        entries.append(MemoryEntry(target=target, text=text, fingerprint=fp))
    return entries


def _serialize_entries(entries: list[MemoryEntry]) -> str:
    if not entries:
        return ""
    body = f"\n{ENTRY_DELIMITER}\n".join(entry.text for entry in entries)
    return body + "\n"


def _cap_to_limit(entries: list[MemoryEntry], limit: int) -> list[MemoryEntry]:
    """Drop entries from the tail until the serialized size fits ``limit``."""
    kept = list(entries)
    while kept and serialized_size(kept) > limit:
        kept.pop()
    return kept


def _cap_with_eviction(
    entries: list[MemoryEntry],
    limit: int,
    *,
    protected: frozenset[str],
    evict_first: frozenset[str],
) -> list[MemoryEntry]:
    """Fit ``entries`` under ``limit``, evicting unpinned/agent rows first."""
    kept = list(entries)
    if not kept or serialized_size(kept) <= limit:
        return kept

    def _remove_at(index: int) -> None:
        kept.pop(index)

    def _first_removable(predicate) -> int | None:
        for idx, entry in enumerate(kept):
            if predicate(entry):
                return idx
        return None

    while kept and serialized_size(kept) > limit:
        idx = _first_removable(
            lambda e: e.fingerprint in evict_first and e.fingerprint not in protected
        )
        if idx is not None:
            _remove_at(idx)
            continue
        idx = _first_removable(lambda e: e.fingerprint not in protected)
        if idx is not None:
            _remove_at(idx)
            continue
        # Protected entries alone exceed the limit — drop from tail.
        kept.pop()
    return kept


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)
