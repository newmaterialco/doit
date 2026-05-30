"""Read/write Hermes' native per-profile memory files.

Hermes stores curated, bounded memory on disk per profile:

    ~/.hermes/profiles/<profile>/memories/USER.md     (~1,375 chars)
    ~/.hermes/profiles/<profile>/memories/MEMORY.md   (~2,200 chars)

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
app, and we never delete agent-managed entries.
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

# Hermes' on-disk format uses the section sign as the entry delimiter.
ENTRY_DELIMITER = "§"

# Hermes' default character limits per docs. We mirror them here so we never
# write a file Hermes would refuse to load.
USER_CHAR_LIMIT = 1375
MEMORY_CHAR_LIMIT = 2200

_FILE_BY_TARGET: dict[MemoryTarget, str] = {
    "user": "USER.md",
    "memory": "MEMORY.md",
}

_LIMIT_BY_TARGET: dict[MemoryTarget, int] = {
    "user": USER_CHAR_LIMIT,
    "memory": MEMORY_CHAR_LIMIT,
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

    def __init__(self, profiles_dir: str | os.PathLike[str], profile_name: str) -> None:
        self._memories_dir = Path(profiles_dir).expanduser() / profile_name / "memories"

    @property
    def memories_dir(self) -> Path:
        return self._memories_dir

    def path_for(self, target: MemoryTarget) -> Path:
        return self._memories_dir / _FILE_BY_TARGET[target]

    def limit_for(self, target: MemoryTarget) -> int:
        return _LIMIT_BY_TARGET[target]

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

    def write_entries(self, target: MemoryTarget, entries: Iterable[str]) -> list[MemoryEntry]:
        """Replace the on-disk file with ``entries``.

        Whitespace-only entries are dropped. Duplicates (by fingerprint) are
        merged keeping the first occurrence. If the combined character count
        exceeds Hermes' limit, oldest entries are dropped from the tail until
        it fits — never silently truncated mid-entry, because Hermes parses
        entries as whole blocks.

        Returns the entries actually written, in order.
        """
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

        limit = self.limit_for(target)
        capped = _cap_to_limit(normalized, limit)
        _atomic_write(self.path_for(target), _serialize_entries(capped))
        return capped

    def stage_pinned_entries(
        self,
        target: MemoryTarget,
        pinned_texts: Iterable[str],
    ) -> tuple[list[MemoryEntry], list[str]]:
        """Append user-pinned entries to ``target`` if they aren't already there.

        Existing on-disk entries (whether agent-curated or previously pinned)
        are preserved. Pinned texts that would push the file past Hermes'
        char limit are dropped from the end and returned in ``skipped`` so
        the caller can surface a sync error for them.

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

        limit = self.limit_for(target)
        combined = existing + new_entries
        capped = _cap_to_limit(combined, limit)
        kept_fps = {entry.fingerprint for entry in capped}
        skipped = [entry.text for entry in new_entries if entry.fingerprint not in kept_fps]
        _atomic_write(self.path_for(target), _serialize_entries(capped))
        return capped, skipped


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


def fingerprint(text: str) -> str:
    """Stable, normalized hash for an entry. Short for compact storage."""
    norm = _canonicalize(text)
    return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:32]


def _canonicalize(text: str) -> str:
    """Reduce trivial whitespace differences so the same fact hashes alike."""
    collapsed = re.sub(r"\s+", " ", text).strip()
    return collapsed.lower()


def _normalize_entry(text: str) -> str:
    """Strip outer whitespace; reject empties. Internal whitespace stays."""
    if text is None:
        return ""
    return text.strip()


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
    while kept and len(_serialize_entries(kept)) > limit:
        kept.pop()
    return kept


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)
