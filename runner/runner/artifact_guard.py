"""Relevance gate for [[DOIT_ARTIFACT]] blocks before persisting to Supabase.

Blocks off-topic artifacts (e.g. a prior todo's moving-company sheet
landing on a Jackson Hole fishing task) while allowing deliverables whose
URLs appeared in this run's tool outputs.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse

from .events import ArtifactRequest

log = logging.getLogger(__name__)

_URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.IGNORECASE)

_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
    "is", "it", "of", "on", "or", "the", "to", "with", "your", "this",
    "that", "task", "todo", "draft", "email", "send", "top", "about",
}


def _tokens(text: str) -> set[str]:
    raw = re.findall(r"[a-z0-9]+", (text or "").lower())
    return {t for t in raw if len(t) > 2 and t not in _STOPWORDS}


def task_keywords(todo: dict) -> set[str]:
    parts = [
        str(todo.get("title") or ""),
        str(todo.get("detail") or ""),
        str(todo.get("topic") or ""),
        str(todo.get("original_title") or ""),
    ]
    return _tokens(" ".join(parts))


def artifact_keywords(artifact: ArtifactRequest) -> set[str]:
    parts = [artifact.title or "", artifact.key or "", artifact.kind or ""]
    payload = artifact.payload or {}
    if isinstance(payload, dict):
        for key in ("subject", "body", "text", "title", "url"):
            val = payload.get(key)
            if isinstance(val, str):
                parts.append(val[:500])
            elif isinstance(val, list):
                parts.extend(str(x) for x in val[:5])
    return _tokens(" ".join(parts))


def extract_urls_from_text(text: str) -> set[str]:
    if not text:
        return set()
    return {_normalize_url(u) for u in _URL_RE.findall(text) if _normalize_url(u)}


def _normalize_url(url: str) -> str:
    u = (url or "").strip().rstrip(".,;)")
    if not u:
        return ""
    try:
        parsed = urlparse(u)
        if not parsed.scheme or not parsed.netloc:
            return u.lower()
        path = parsed.path.rstrip("/")
        return f"{parsed.scheme.lower()}://{parsed.netloc.lower()}{path}".lower()
    except Exception:
        return u.lower()


def extract_urls_from_value(value: Any) -> set[str]:
    if value is None:
        return set()
    if isinstance(value, str):
        return extract_urls_from_text(value)
    if isinstance(value, dict):
        out: set[str] = set()
        for v in value.values():
            out |= extract_urls_from_value(v)
        return out
    if isinstance(value, list):
        out = set()
        for item in value:
            out |= extract_urls_from_value(item)
        return out
    return set()


def artifact_urls(artifact: ArtifactRequest) -> set[str]:
    urls = extract_urls_from_value(artifact.payload)
    if artifact.title:
        urls |= extract_urls_from_text(artifact.title)
    return urls


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    inter = a & b
    union = a | b
    return len(inter) / len(union)


def _distinctive_overlap(a: set[str], b: set[str]) -> bool:
    """True when a token length >= 5 appears in both sets."""
    strong_a = {t for t in a if len(t) >= 5}
    strong_b = {t for t in b if len(t) >= 5}
    return bool(strong_a & strong_b)


def artifact_matches_task(
    todo: dict,
    artifact: ArtifactRequest,
    seen_urls: set[str] | frozenset[str],
) -> bool:
    """Return True when an artifact plausibly belongs to this todo."""
    if artifact.kind in ("audio", "image"):
        return True

    urls = artifact_urls(artifact)
    if urls and seen_urls and urls & set(seen_urls):
        return True

    task_kw = task_keywords(todo)
    art_kw = artifact_keywords(artifact)
    if not task_kw or not art_kw:
        return True

    if _distinctive_overlap(task_kw, art_kw):
        return True
    if _jaccard(task_kw, art_kw) >= 0.15:
        return True

    return False


@dataclass
class RunUrlTracker:
    """Collects URLs observed in tool outputs during one Hermes run."""

    urls: set[str] = field(default_factory=set)

    def observe_text(self, text: str | None) -> None:
        if text:
            self.urls |= extract_urls_from_text(text)

    def observe_value(self, value: Any) -> None:
        self.urls |= extract_urls_from_value(value)

    def observe_tool_result(self, data: dict[str, Any]) -> None:
        output = data.get("output")
        if output is None:
            return
        if isinstance(output, str):
            self.observe_text(output)
            try:
                self.observe_value(json.loads(output))
            except json.JSONDecodeError:
                pass
        else:
            self.observe_value(output)


def maybe_upsert_artifact(
    db: Any,
    *,
    todo: dict,
    artifact: ArtifactRequest,
    user_id: str,
    run_id: str,
    url_tracker: RunUrlTracker | None,
) -> bool:
    """Upsert when relevant; log and skip off-topic artifacts. Returns True if persisted."""
    todo_id = str(todo["id"])
    if url_tracker is not None and not artifact_matches_task(
        todo, artifact, url_tracker.urls
    ):
        log.warning(
            "artifact_rejected_off_topic todo=%s key=%s title=%r",
            todo_id,
            artifact.key,
            artifact.title,
        )
        return False
    db.upsert_artifact(
        todo_id=todo_id,
        user_id=user_id,
        key=artifact.key,
        kind=artifact.kind,
        title=artifact.title,
        payload=artifact.payload,
        hermes_run_id=run_id,
    )
    if url_tracker is not None:
        url_tracker.urls |= artifact_urls(artifact)
    return True
