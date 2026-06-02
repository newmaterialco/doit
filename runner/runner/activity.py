"""Normalize Hermes SSE events into a live agent-activity snapshot.

The translator in `runner/events.py` already maps each Hermes event to a
`Translated` effect we persist into `todo_steps`. Those rows are great for
the audit log but they make a poor live-status surface: the iOS app would
have to scan the tail, dedupe, decide which row is "current", and re-derive
human labels. We centralize that work here.

The product surface that consumes this snapshot lives in three places on
iOS:

  * The status line on the todo card ("Searching Gmail…").
  * The animated activity card at the top of the task detail view.
  * The ActivityKit Live Activity widget (Lock Screen / Dynamic Island).

All three want the same canonical label, icon family, and recency
information, so we compute them once here and write a single
``todo_agent_activity`` row per todo via ``DB.upsert_agent_activity``.

This module is intentionally event-shape aware (it inspects the raw event
name) but is otherwise pure-Python so it can be unit-tested without any
network or Supabase. The runner owns the DB write; this service only
returns the dict that should be persisted.
"""
from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from .events import (
    INTERACTION_CLOSE,
    INTERACTION_OPEN,
    ARTIFACT_OPEN,
    ARTIFACT_CLOSE,
    Translated,
)

# Most-recent steps we surface in the snapshot payload. Older history lives
# in `todo_steps`; the snapshot only carries enough context to draw the
# Chowder-style "previous intent" stack on the Live Activity / detail card.
_MAX_RECENT_STEPS = 8

# Cap the title/detail copy at sensible UI widths. The DB also enforces
# this via CHECK constraints; clamping client-side avoids 400s on noisy
# events that emit huge strings.
_TITLE_LIMIT = 180
_DETAIL_LIMIT = 360


@dataclass
class ActivityStep:
    """One normalized step we surface in the activity snapshot payload."""

    title: str
    detail: str | None
    tool_name: str | None
    tool_category: str | None
    started_at: str
    completed_at: str | None = None

    def to_payload(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "title": self.title,
            "started_at": self.started_at,
        }
        if self.detail:
            out["detail"] = self.detail
        if self.tool_name:
            out["tool_name"] = self.tool_name
        if self.tool_category:
            out["tool_category"] = self.tool_category
        if self.completed_at:
            out["completed_at"] = self.completed_at
        return out


@dataclass
class ActivitySnapshot:
    """Current operational state of a single Hermes run."""

    phase: str
    state: str
    title: str
    detail: str | None = None
    tool_name: str | None = None
    tool_call_id: str | None = None
    tool_category: str | None = None
    recent: list[ActivityStep] = field(default_factory=list)
    started_at: str = ""
    completed_at: str | None = None

    def to_db_fields(self, *, hermes_run_id: str | None) -> dict[str, Any]:
        """Shape this snapshot into the `todo_agent_activity` columns."""
        payload = {"steps": [s.to_payload() for s in self.recent]}
        fields: dict[str, Any] = {
            "phase": self.phase,
            "state": self.state,
            "title": _clip(self.title, _TITLE_LIMIT) or "Working…",
            "detail": _clip(self.detail, _DETAIL_LIMIT) if self.detail else None,
            "tool_name": self.tool_name,
            "tool_call_id": self.tool_call_id,
            "tool_category": self.tool_category,
            "hermes_run_id": hermes_run_id,
            "payload": payload,
            "updated_at": _now_iso(),
            # Always include this column so a resumed / paused / running
            # snapshot clears any terminal timestamp left by a previous
            # completed run on the same todo activity row.
            "completed_at": self.completed_at,
        }
        return fields


class AgentActivityService:
    """Stateful translator from Hermes events to a current-activity snapshot.

    One instance per active run. The runner instantiates a service when it
    claims a todo, calls ``observe(...)`` on every SSE event it recognizes,
    and ``mark_terminal(...)`` once the run lands in a terminal state.
    Persistence is the runner's responsibility — this class never touches
    the DB.
    """

    def __init__(self) -> None:
        self._started_at: str = _now_iso()
        # We append to the right and trim from the left so the most recent
        # step is always last. `deque` keeps the cap cheap.
        self._recent: deque[ActivityStep] = deque(maxlen=_MAX_RECENT_STEPS)
        self._current_tool: ActivityStep | None = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def initial(self, *, phase: str = "starting", title: str = "Starting…") -> ActivitySnapshot:
        """Snapshot to write when we first claim a todo, before any SSE.

        Keeps the UI from sitting on a stale "Ready to get started" line
        in the gap between status flipping to `running` and the first
        Hermes event landing.
        """
        return ActivitySnapshot(
            phase=phase,
            state="running",
            title=title,
            started_at=self._started_at,
            recent=list(self._recent),
        )

    def observe(
        self,
        effect: Translated | None,
        *,
        event_name: str | None = None,
        raw_data: dict[str, Any] | None = None,
    ) -> ActivitySnapshot | None:
        """Update internal state from one Hermes event.

        Returns a snapshot ready to upsert, or ``None`` if the event
        doesn't change the user-visible status (e.g. we already surfaced
        a richer label for the same call_id).
        """
        if effect is None:
            return None

        actual_event = ""
        if raw_data is not None:
            actual_event = str(raw_data.get("event") or event_name or "")
        elif event_name:
            actual_event = event_name

        # Tool start: open a tool intent we'll later close on the matching
        # `tool_result` / `function_call_output`.
        if effect.step_kind == "tool_started":
            title, detail, category = _label_for_tool_started(effect)
            now = _now_iso()
            step = ActivityStep(
                title=title,
                detail=detail,
                tool_name=effect.tool_name,
                tool_category=category,
                started_at=now,
            )
            tool_call_id = _extract_call_id(raw_data)
            self._current_tool = step
            self._push_recent(step)
            return ActivitySnapshot(
                phase="tool",
                state="running",
                title=title,
                detail=detail,
                tool_name=effect.tool_name,
                tool_call_id=tool_call_id,
                tool_category=category,
                started_at=self._started_at,
                recent=list(self._recent),
            )

        if effect.step_kind == "tool_result":
            title, detail, category = _label_for_tool_result(effect)
            now = _now_iso()
            if self._current_tool is not None:
                self._current_tool.completed_at = now
                # Mark the matching step in `_recent` as completed so the
                # iOS "previous intents" stack shows a finished pill.
                for step in reversed(self._recent):
                    if step.tool_name == self._current_tool.tool_name and step.completed_at is None:
                        step.completed_at = now
                        break
            self._current_tool = None
            return ActivitySnapshot(
                phase="tool_done",
                state="running",
                title=title,
                detail=detail,
                tool_name=effect.tool_name,
                tool_call_id=_extract_call_id(raw_data),
                tool_category=category,
                started_at=self._started_at,
                recent=list(self._recent),
            )

        if effect.step_kind == "thought":
            text = (effect.text or "").strip()
            # Reasoning text often contains structured markers we never
            # want to leak into a status line; we already filter those in
            # `events.translate` but double-check defensively.
            for marker in (INTERACTION_OPEN, INTERACTION_CLOSE, ARTIFACT_OPEN, ARTIFACT_CLOSE):
                if marker in text:
                    return None
            short = _shorten_thought(text)
            step = ActivityStep(
                title="Thinking",
                detail=short,
                tool_name=None,
                tool_category="thinking",
                started_at=_now_iso(),
            )
            self._push_recent(step)
            return ActivitySnapshot(
                phase="thinking",
                state="running",
                title="Thinking",
                detail=short,
                tool_category="thinking",
                started_at=self._started_at,
                recent=list(self._recent),
            )

        if effect.step_kind == "oauth_needed":
            step = ActivityStep(
                title="Waiting on you to connect an account",
                detail=effect.text or None,
                tool_name=effect.tool_name,
                tool_category="oauth",
                started_at=_now_iso(),
            )
            self._push_recent(step)
            return ActivitySnapshot(
                phase="needs_auth",
                state="paused",
                title="Connect an account to continue",
                detail=effect.text or None,
                tool_name=effect.tool_name,
                tool_category="oauth",
                started_at=self._started_at,
                recent=list(self._recent),
            )

        if effect.step_kind == "input_needed":
            prompt = (effect.text or "Needs your input").strip()
            step = ActivityStep(
                title="Waiting on your reply",
                detail=prompt,
                tool_name=None,
                tool_category="question",
                started_at=_now_iso(),
            )
            self._push_recent(step)
            return ActivitySnapshot(
                phase="needs_input",
                state="paused",
                title="Needs your input",
                detail=prompt,
                tool_category="question",
                started_at=self._started_at,
                recent=list(self._recent),
            )

        if effect.step_kind == "final":
            text = (effect.text or "Done.").strip() or "Done."
            now = _now_iso()
            step = ActivityStep(
                title="Wrapped up",
                detail=text[:_DETAIL_LIMIT],
                tool_name=None,
                tool_category="final",
                started_at=now,
                completed_at=now,
            )
            self._push_recent(step)
            return ActivitySnapshot(
                phase="final",
                state="completed",
                title="Done",
                detail=text[:_DETAIL_LIMIT],
                tool_category="final",
                started_at=self._started_at,
                completed_at=now,
                recent=list(self._recent),
            )

        if effect.step_kind == "error":
            msg = (effect.text or "Run failed").strip() or "Run failed"
            now = _now_iso()
            step = ActivityStep(
                title="Failed",
                detail=msg[:_DETAIL_LIMIT],
                tool_name=effect.tool_name,
                tool_category="error",
                started_at=now,
                completed_at=now,
            )
            self._push_recent(step)
            return ActivitySnapshot(
                phase="failed",
                state="failed",
                title="Failed",
                detail=msg[:_DETAIL_LIMIT],
                tool_name=effect.tool_name,
                tool_category="error",
                started_at=self._started_at,
                completed_at=now,
                recent=list(self._recent),
            )

        # Unknown / no-op event. Don't churn the row.
        del actual_event
        return None

    def mark_terminal(
        self,
        *,
        state: str,
        title: str,
        detail: str | None = None,
        phase: str | None = None,
    ) -> ActivitySnapshot:
        """Snapshot to write when a run lands in a terminal state.

        Called from the runner's terminal branches (done / failed /
        needs_input / needs_auth / cancelled). Keeps the iOS surfaces
        from showing a stale "Working on…" label once the run is over.
        """
        now = _now_iso()
        snap = ActivitySnapshot(
            phase=phase or state,
            state=state,
            title=title,
            detail=detail,
            started_at=self._started_at,
            recent=list(self._recent),
        )
        if state in {"completed", "failed", "cancelled"}:
            snap.completed_at = now
        return snap

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _push_recent(self, step: ActivityStep) -> None:
        # We collapse consecutive duplicate thoughts so the "previous
        # intent" stack doesn't fill up with eight identical "Thinking"
        # entries on a slow reasoning turn.
        if self._recent:
            last = self._recent[-1]
            if (
                last.title == step.title
                and last.tool_name == step.tool_name
                and last.detail == step.detail
            ):
                return
        self._recent.append(step)


# =========================================================================
# Helpers
# =========================================================================


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _clip(value: str | None, limit: int) -> str | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "\u2026"


_TOOL_VERB_OVERRIDES: dict[str, str] = {
    "search": "Searching",
    "send": "Sending",
    "draft": "Drafting",
    "create": "Creating",
    "update": "Updating",
    "delete": "Removing",
    "list": "Listing",
    "fetch": "Fetching",
    "get": "Fetching",
    "read": "Reading",
    "write": "Writing",
    "open": "Opening",
    "schedule": "Scheduling",
    "summarize": "Summarizing",
    "convert": "Converting",
    "text_to_speech": "Generating spoken summary",
}


# Map a tool slug into a coarse category the iOS app uses to pick an
# SF Symbol. Keep this list small and aligned with the assets we already
# ship; unknown tools fall back to `unknown` which renders as a generic
# tool icon on iOS.
_TOOL_CATEGORY_HINTS: tuple[tuple[str, str], ...] = (
    ("gmail", "gmail"),
    ("googlemail", "gmail"),
    ("googlecalendar", "calendar"),
    ("calendar", "calendar"),
    ("googlesheets", "sheets"),
    ("sheet", "sheets"),
    ("googledocs", "docs"),
    ("docs", "docs"),
    ("googledrive", "drive"),
    ("drive", "drive"),
    ("notion", "notion"),
    ("slack", "slack"),
    ("text_to_speech", "audio"),
    ("speech", "audio"),
    ("voice", "audio"),
    ("audio", "audio"),
    ("composio_manage_connections", "oauth"),
    ("composio_wait", "oauth"),
    ("connect", "oauth"),
    ("search", "search"),
    ("browse", "browser"),
    ("fetch_url", "browser"),
    ("http", "browser"),
    ("instacart", "instacart"),
    ("twitter", "twitter"),
    ("reddit", "reddit"),
)


_NAME_TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


def _categorize_tool(tool_name: str | None) -> str:
    if not tool_name:
        return "unknown"
    name = tool_name.lower()
    for hint, category in _TOOL_CATEGORY_HINTS:
        if hint in name:
            return category
    return "unknown"


def _humanize_tool_name(tool_name: str | None) -> str:
    """Build a user-visible label like "Searching Gmail" from a slug."""
    if not tool_name:
        return "Running a tool"
    if tool_name == "text_to_speech":
        return "Generating spoken summary"
    tokens = _NAME_TOKEN_RE.findall(tool_name.lower())
    if not tokens:
        return "Running a tool"
    verb_key = tokens[-1]
    verb = _TOOL_VERB_OVERRIDES.get(verb_key)
    target_tokens: list[str] = []
    for token in tokens[:-1]:
        if not token:
            continue
        if token in {"composio", "tool", "v1"}:
            continue
        target_tokens.append(token)
    if not target_tokens:
        target_tokens = tokens
        verb = None
    target = " ".join(_pretty_token(t) for t in target_tokens)
    if verb:
        return f"{verb} {target}".strip()
    return f"Using {target}".strip()


_TOKEN_PRETTY_OVERRIDES: dict[str, str] = {
    "gmail": "Gmail",
    "googlecalendar": "Google Calendar",
    "googlemail": "Gmail",
    "googlesheets": "Google Sheets",
    "googledocs": "Google Docs",
    "googledrive": "Google Drive",
    "notion": "Notion",
    "slack": "Slack",
    "instacart": "Instacart",
    "twitter": "Twitter",
    "reddit": "Reddit",
}


def _pretty_token(token: str) -> str:
    return _TOKEN_PRETTY_OVERRIDES.get(token, token.capitalize())


def _label_for_tool_started(effect: Translated) -> tuple[str, str | None, str]:
    """(title, detail, category) for an in-flight tool call.

    The translator's text often already carries a useful preview
    ("Using gmail_search. {...}"). We strip the leading "Using <slug>."
    boilerplate and keep the preview as the secondary detail line.
    """
    tool = effect.tool_name
    title = _humanize_tool_name(tool)
    category = _categorize_tool(tool)
    detail: str | None = None
    raw_text = (effect.text or "").strip()
    # Strip the redundant "Using <tool>." prefix the translator prepends
    # so the detail line is just the preview.
    if raw_text:
        for prefix in (f"Using {tool}.", f"Using {tool}", "Generating spoken summary."):
            if prefix and raw_text.startswith(prefix):
                raw_text = raw_text[len(prefix):].strip()
        if raw_text:
            detail = _clip(raw_text, _DETAIL_LIMIT)
    return title, detail, category


def _label_for_tool_result(effect: Translated) -> tuple[str, str | None, str]:
    """(title, detail, category) for a freshly completed tool call."""
    tool = effect.tool_name
    base = _humanize_tool_name(tool)
    # Past-tense-ish: "Searching" -> "Reviewed", "Drafting" -> "Reviewed".
    # We deliberately keep this simple — the iOS card will animate the
    # shimmer off once `state` flips to `tool_done` regardless.
    title = f"Reviewing {base.split(' ', 1)[1]}" if " " in base else f"Reviewed {base}"
    category = _categorize_tool(tool)
    detail = _clip(effect.text, _DETAIL_LIMIT) if effect.text else None
    return title, detail, category


def _shorten_thought(text: str) -> str | None:
    """Trim a reasoning blurb to a short status line.

    Prefers the first sentence so we surface a coherent fragment rather
    than mid-token gibberish. Returns None on whitespace-only input.
    """
    if not text:
        return None
    # First sentence (period, exclamation, question, newline).
    for sep in (". ", "! ", "? ", "\n"):
        idx = text.find(sep)
        if 0 < idx < 200:
            return text[: idx + 1].strip()
    return _clip(text, 200)


def _extract_call_id(raw_data: dict[str, Any] | None) -> str | None:
    if not raw_data:
        return None
    direct = raw_data.get("call_id") or raw_data.get("tool_call_id")
    if direct:
        return str(direct)
    item = raw_data.get("item")
    if isinstance(item, dict):
        nested = item.get("call_id") or item.get("id")
        if nested:
            return str(nested)
    return None
