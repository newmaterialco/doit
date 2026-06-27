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
from datetime import datetime, timezone
from typing import Any

UTC = timezone.utc

from .events import (
    INTERACTION_CLOSE,
    INTERACTION_OPEN,
    ARTIFACT_OPEN,
    ARTIFACT_CLOSE,
    ACTIVITY_OPEN,
    ACTIVITY_CLOSE,
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

    def initial(
        self,
        *,
        phase: str = "starting",
        title: str = "Starting…",
        detail: str | None = None,
    ) -> ActivitySnapshot:
        """Snapshot to write when we first claim a todo, before any SSE.

        Keeps the UI from sitting on a stale "Ready to get started" line
        in the gap between status flipping to `running` and the first
        Hermes event landing.
        """
        detail_text = detail if detail is not None else title
        return ActivitySnapshot(
            phase=phase,
            state="running",
            title=title,
            detail=detail_text,
            tool_category="thinking",
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
            for marker in (
                INTERACTION_OPEN,
                INTERACTION_CLOSE,
                ARTIFACT_OPEN,
                ARTIFACT_CLOSE,
                ACTIVITY_OPEN,
                ACTIVITY_CLOSE,
            ):
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

    def stalled(self, latest: ActivitySnapshot | None = None) -> ActivitySnapshot:
        """Snapshot for a run with no SSE progress past the stall timeout.

        Distinct ``phase="stalled"`` (state stays ``running``) so iOS can show
        "Still working — this is taking longer than usual" copy instead of the
        generic shimmer. Keeps the last known tool context so the card still
        says *what* it's stuck on.
        """
        title = "Still working — checking results…"
        detail = "This is taking longer than usual…"
        if _is_active_browser_snapshot(latest):
            title = "Browser is taking longer than usual"
            detail = _browser_stalled_detail(latest)
        elif latest is not None and latest.title and latest.title != "Still working":
            detail = f"Still on: {latest.title}"
        return ActivitySnapshot(
            phase="stalled",
            state="running",
            title=title,
            detail=detail,
            tool_name=latest.tool_name if latest else None,
            tool_call_id=latest.tool_call_id if latest else None,
            tool_category=(latest.tool_category if latest else None) or "thinking",
            started_at=self._started_at,
            recent=list(self._recent),
        )

    def heartbeat(self, latest: ActivitySnapshot | None = None) -> ActivitySnapshot:
        """Refresh the live row during long gaps between Hermes events.

        Some model calls or tool executions can run for minutes without
        emitting SSE progress. The iOS app still needs a fresh activity row so
        the live surfaces don't look stuck on an old placeholder. Reuse the
        latest meaningful snapshot when we have one; otherwise publish a
        neutral "still working" state without claiming a specific action.
        """
        if latest is not None:
            if latest.phase == "starting" and not self._recent:
                return self.initial(phase="starting", title="Connecting…", detail=None)
            if _is_active_browser_snapshot(latest):
                title, detail = _browser_heartbeat_copy(latest)
                return ActivitySnapshot(
                    phase=latest.phase,
                    state=latest.state,
                    title=title,
                    detail=detail,
                    tool_name=latest.tool_name,
                    tool_call_id=latest.tool_call_id,
                    tool_category=latest.tool_category,
                    started_at=self._started_at,
                    recent=list(self._recent),
                )
            return ActivitySnapshot(
                phase=latest.phase,
                state=latest.state,
                title=latest.title,
                detail=latest.detail,
                tool_name=latest.tool_name,
                tool_call_id=latest.tool_call_id,
                tool_category=latest.tool_category,
                started_at=self._started_at,
                recent=list(self._recent),
            )
        return ActivitySnapshot(
            phase="thinking",
            state="running",
            title="Still working",
            detail="Still working on this",
            tool_category="thinking",
            started_at=self._started_at,
            recent=list(self._recent),
        )

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


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _elapsed_seconds_since(value: str | None) -> float | None:
    parsed = _parse_iso(value)
    if parsed is None:
        return None
    return max(0.0, (datetime.now(UTC) - parsed).total_seconds())


def _clip(value: str | None, limit: int) -> str | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "\u2026"


def execution_start_snapshot(
    todo: dict,
    *,
    pending_messages: list[str] | None = None,
    resumed_from_interaction: bool = False,
) -> ActivitySnapshot:
    """User-visible activity while Hermes spins up for a claimed todo.

    Never echoes ``todo.title`` — the iOS header already shows the task;
    activity surfaces should show process labels only.
    """
    del todo  # reserved for future context; bootstrap copy is generic today.
    service = AgentActivityService()
    if pending_messages:
        label = "Reading your message…"
    elif resumed_from_interaction:
        label = "Picking up your answer…"
    else:
        label = "Getting ready…"
    return service.initial(phase="starting", title=label, detail=None)


def prep_queue_snapshot(*, summary: str | None = None) -> ActivitySnapshot:
    """Activity row written when prep finishes and the todo is queued."""
    del summary  # prep summary stays on the list card during preparing status.
    service = AgentActivityService()
    return service.initial(phase="starting", title="Queued to run…", detail=None)


def _is_active_browser_snapshot(latest: ActivitySnapshot | None) -> bool:
    if latest is None:
        return False
    return latest.tool_category == "browser" and latest.phase in {"tool", "stalled"}


def _active_browser_step(latest: ActivitySnapshot) -> ActivityStep | None:
    for step in reversed(latest.recent):
        if (
            step.tool_category == "browser"
            and step.completed_at is None
            and (
                latest.tool_name is None
                or step.tool_name is None
                or step.tool_name == latest.tool_name
            )
        ):
            return step
    return None


def _browser_elapsed_seconds(latest: ActivitySnapshot) -> float | None:
    step = _active_browser_step(latest)
    if step is not None:
        return _elapsed_seconds_since(step.started_at)
    return _elapsed_seconds_since(latest.started_at)


def _browser_context_label(latest: ActivitySnapshot) -> str:
    title = (latest.title or "").strip()
    if title and title not in {"Still working", "Browser is still working"}:
        return title
    return "the browser step"


def _browser_heartbeat_copy(latest: ActivitySnapshot) -> tuple[str, str | None]:
    elapsed = _browser_elapsed_seconds(latest)
    context = _browser_context_label(latest)
    if elapsed is None:
        return "Browser is still working", f"Still on: {context}"
    if elapsed >= 180:
        return "Browser is still running this step", f"Still waiting on: {context}"
    if elapsed >= 60:
        return "Still waiting on the page", f"Browser has been on: {context}"
    return "Browsing the site…", latest.detail or f"Working on: {context}"


def _browser_stalled_detail(latest: ActivitySnapshot | None) -> str:
    if latest is None:
        return "The browser session has been quiet for a while."
    context = _browser_context_label(latest)
    elapsed = _browser_elapsed_seconds(latest)
    if elapsed is None:
        return f"Still waiting on: {context}"
    return f"Still waiting on: {context} ({int(elapsed)}s without an update)"


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
    "navigate": "Browsing",
    "snapshot": "Reading",
    "click": "Clicking",
    "type": "Typing",
    "scroll": "Scrolling",
    "vision": "Inspecting",
    "back": "Browsing",
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
    ("browser_", "browser"),
    ("browserbase", "browser"),
    ("search", "search"),
    ("skills_list", "search"),
    ("skill_view", "search"),
    ("skills_search", "search"),
    ("browse", "browser"),
    ("fetch_url", "browser"),
    ("http", "browser"),
    ("instacart", "instacart"),
    ("twitter", "twitter"),
    ("reddit", "reddit"),
    ("hunter", "hunter"),
    ("linkedin", "linkedin"),
    ("figma", "figma"),
)


_NAME_TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


def _categorize_tool(tool_name: str | None, text: str | None = None) -> str:
    if _is_browse_skill_terminal_call(tool_name, text):
        return "browser"
    if _is_browse_terminal_call(tool_name, text):
        return "browser"
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
    browser_label = _browser_tool_label(tool_name)
    if browser_label is not None:
        return browser_label
    figma_label = _figma_tool_label(tool_name)
    if figma_label is not None:
        return figma_label
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


def _is_browse_terminal_call(tool_name: str | None, text: str | None) -> bool:
    if not tool_name or not text:
        return False
    name = tool_name.lower()
    if not any(token in name for token in ("terminal", "shell", "command", "execute")):
        return False
    return re.search(r"(^|\s)browse(\s|$)", text.lower()) is not None


def _is_browse_skill_terminal_call(tool_name: str | None, text: str | None) -> bool:
    if not tool_name or not text:
        return False
    name = tool_name.lower()
    if not any(token in name for token in ("terminal", "shell", "command", "execute")):
        return False
    lowered = text.lower()
    return (
        "sync_browse_skill.py" in lowered
        or re.search(r"(^|\s)browse\s+skills\s+(find|add)(\s|$)", lowered) is not None
    )


def _browser_tool_label(tool_name: str) -> str | None:
    name = tool_name.lower()
    labels = {
        "browser_navigate": "Browsing the web",
        "browser_snapshot": "Reading web page",
        "browser_click": "Clicking web page",
        "browser_type": "Typing on web page",
        "browser_scroll": "Scrolling web page",
        "browser_press": "Pressing browser key",
        "browser_back": "Browsing back",
        "browser_get_images": "Finding page images",
        "browser_vision": "Inspecting browser screenshot",
        "browser_console": "Checking browser console",
        "browser_cdp": "Inspecting browser session",
        "browser_dialog": "Handling browser dialog",
    }
    if name in labels:
        return labels[name]
    if name.startswith("browser_"):
        return "Browsing the web"
    return None


def _figma_tool_label(tool_name: str) -> str | None:
    """Friendly labels for official Figma MCP tool names.

    The production profile currently uses Composio for Figma. If an
    authenticated Figma MCP bridge is added later, these labels keep the
    live activity UI from showing raw names like ``use_figma``.
    """
    name = tool_name.lower()
    if name == "use_figma":
        return "Editing Figma canvas"
    if name == "upload_assets":
        return "Uploading assets to Figma"
    if name == "create_new_file":
        return "Creating Figma file"
    if name == "generate_diagram":
        return "Generating FigJam diagram"
    if name == "generate_figma_design":
        return "Capturing UI to Figma"
    if name == "get_design_context":
        return "Reading Figma design context"
    if name == "get_metadata":
        return "Reading Figma structure"
    if name == "get_screenshot":
        return "Capturing Figma screenshot"
    if name == "get_variable_defs":
        return "Reading Figma variables"
    if name == "search_design_system":
        return "Searching Figma design system"
    if name in {"get_libraries", "get_code_connect_map", "get_code_connect_suggestions"}:
        return "Reading Figma component mappings"
    return None


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
    "hunter": "Hunter",
    "linkedin": "LinkedIn",
    "figma": "Figma",
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
    category = _categorize_tool(tool, effect.text)
    if _is_browse_skill_terminal_call(tool, effect.text):
        title = "Finding browser skill"
    elif _is_browse_terminal_call(tool, effect.text):
        title = "Browsing the web"
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
    raw_text = (effect.text or "").strip()
    category = _categorize_tool(tool, effect.text)
    is_browse_skill = _is_browse_skill_terminal_call(tool, effect.text)
    if is_browse_skill:
        base = "Browser skill"
    elif _is_browse_terminal_call(tool, effect.text):
        base = "Browser session"
    if "hit an issue" in raw_text.lower() or "tool failed" in raw_text.lower():
        if is_browse_skill:
            target = "Browser skill"
        elif _is_browse_terminal_call(tool, effect.text):
            target = "Browser session"
        else:
            target = base.split(" ", 1)[1] if " " in base else base
        title = f"{target} hit an issue"
        detail = _clip(raw_text, _DETAIL_LIMIT) if raw_text else None
        return title, detail, category
    if is_browse_skill:
        return "Updated browser skill", _clip(raw_text, _DETAIL_LIMIT) if raw_text else None, category
    if _is_browse_terminal_call(tool, effect.text):
        return "Reviewed browser session", _clip(raw_text, _DETAIL_LIMIT) if raw_text else None, category
    # Past-tense-ish: "Searching" -> "Reviewed", "Drafting" -> "Reviewed".
    # We deliberately keep this simple — the iOS card will animate the
    # shimmer off once `state` flips to `tool_done` regardless.
    title = f"Reviewing {base.split(' ', 1)[1]}" if " " in base else f"Reviewed {base}"
    detail = _clip(raw_text, _DETAIL_LIMIT) if raw_text else None
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
