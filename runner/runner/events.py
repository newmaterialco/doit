"""Translate Hermes SSE events into doit todo_steps + status transitions."""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any, Literal

log = logging.getLogger(__name__)

# Marker the agent uses to wrap a structured ask-the-user payload in its final
# reply. Defined here so the parser stays free of network deps.
INTERACTION_OPEN = "[[DOIT_INTERACTION]]"
INTERACTION_CLOSE = "[[/DOIT_INTERACTION]]"

# Marker the agent uses to surface a user-facing deliverable (a created
# doc/sheet link, a sent email, a calendar invite, a text result) in its
# final reply. Multiple blocks per reply are allowed; each block becomes
# one row in ``todo_artifacts`` keyed by ``artifact_key``.
ARTIFACT_OPEN = "[[DOIT_ARTIFACT]]"
ARTIFACT_CLOSE = "[[/DOIT_ARTIFACT]]"

# Marker for todos the agent wants the app to create after discovering work
# (e.g. inbox scan). Distinct from prep-time [[DOIT_PREP]] tasks[] splitting.
TASKS_OPEN = "[[DOIT_TASKS]]"
TASKS_CLOSE = "[[/DOIT_TASKS]]"

# Marker the agent may emit in reasoning/text to update the app's live
# progress UI with public, user-facing copy. This is separate from private
# reasoning and raw tool previews; the runner strips the markers before
# persisting visible chat text.
ACTIVITY_OPEN = "[[DOIT_ACTIVITY]]"
ACTIVITY_CLOSE = "[[/DOIT_ACTIVITY]]"

# Kinds we know how to render on iOS. Anything else is dropped on the floor
# rather than persisted with an unknown kind, since the UI has no fallback.
_ARTIFACT_KINDS = {"link", "email", "calendar", "text", "audio", "image"}

# Name of the Hermes built-in tool we promote to an audio artifact. The
# runner watches for `function_call` items with this name, captures the
# spoken text, and pairs it with the `function_call_output` that carries
# the generated file path.
TTS_TOOL_NAME = "text_to_speech"

# Hermes built-in tools we surface with their own labels in the activity
# feed instead of the generic "Using <tool>." text. Memory + session search
# are the critical observability for the Hermes-native memory roadmap:
# if the agent never calls them on the second todo of the personal-email
# scenario, the diagnostic is right there in the live log.
_MEMORY_TOOL_NAMES = frozenset({"memory", "remember", "memorize"})
_SESSION_SEARCH_TOOL_NAMES = frozenset({"session_search", "session.search"})


def _friendly_tool_label(name: str | None) -> str | None:
    """Map a Hermes tool name to a short activity-feed label.

    Returns ``None`` when the tool should use the default "Using <name>"
    wording so we never accidentally re-label a non-memory tool.
    """
    if not name:
        return None
    lower = name.lower()
    if lower in _MEMORY_TOOL_NAMES:
        return "Updating long-term memory"
    if lower in _SESSION_SEARCH_TOOL_NAMES:
        return "Searching past tasks for context"
    return None


def _friendly_tool_result_label(name: str | None, is_error: bool) -> str | None:
    """Counterpart of ``_friendly_tool_label`` for ``tool.completed`` events."""
    if not name:
        return None
    lower = name.lower()
    if lower in _MEMORY_TOOL_NAMES:
        return "Memory update failed." if is_error else "Memory updated."
    if lower in _SESSION_SEARCH_TOOL_NAMES:
        return (
            "Couldn't search past tasks."
            if is_error
            else "Past-task search complete."
        )
    return None

# Anything that smells like a Composio OAuth redirect URL the user must visit.
# Composio surfaces these via its connection meta-tools; the exact host varies
# by upstream provider, so we accept any HTTPS URL emitted by a connection tool.
_OAUTH_URL_RE = re.compile(r"https://[^\s'\"<>]+")

_INTERACTION_RE = re.compile(
    re.escape(INTERACTION_OPEN) + r"\s*(\{.*?\})\s*" + re.escape(INTERACTION_CLOSE),
    re.DOTALL,
)

# Captures *everything* between the markers so a malformed first block can't
# greedily swallow a well-formed second one (the JSON braces alone aren't a
# safe stop condition when the inner JSON is broken). The captured body is
# stripped and JSON-parsed separately in ``parse_artifacts``.
_ARTIFACT_RE = re.compile(
    re.escape(ARTIFACT_OPEN) + r"(.*?)" + re.escape(ARTIFACT_CLOSE),
    re.DOTALL,
)

_TASKS_RE = re.compile(
    re.escape(TASKS_OPEN) + r"\s*(\{.*?\})\s*" + re.escape(TASKS_CLOSE),
    re.DOTALL,
)

_ACTIVITY_RE = re.compile(
    re.escape(ACTIVITY_OPEN) + r"(.*?)" + re.escape(ACTIVITY_CLOSE),
    re.DOTALL,
)

_NOISY_ACTIVITY_PATTERNS = (
    re.compile(r"https?://", re.IGNORECASE),
    re.compile(r"\b(function_call|function_call_output|call_id|tool_call_id)\b", re.IGNORECASE),
    re.compile(r"\b(response\.output_item|hermes\.tool|run\.completed)\b", re.IGNORECASE),
    re.compile(r"\b(frompath|topath|cmd|argv|stdin|stdout|stderr)\s*=", re.IGNORECASE),
    re.compile(r"^\s*(event|data|id|retry)\s*:", re.IGNORECASE),
    re.compile(r"^\s*(cd|ls|rg|grep|python|python3|npm|pnpm|yarn|git|curl)\b", re.IGNORECASE),
)


@dataclass
class InteractionRequest:
    """Structured ask-the-user request parsed from the model's final reply."""
    kind: str
    prompt: str
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass
class ArtifactRequest:
    """User-visible deliverable parsed from the model's final reply.

    ``key`` is a stable per-todo identifier the agent can reuse to update
    an artifact in place (e.g. swap a draft URL for the final one). The
    parser falls back to ``kind`` when the agent omits it so a single-
    artifact reply still works without ceremony.
    """
    key: str
    kind: str
    title: str | None = None
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass
class SpawnedTaskRequest:
    """One todo row the agent asks the runner to create."""

    title: str
    source_key: str
    detail: str | None = None
    connection_slug: str | None = None
    summary: str | None = None


@dataclass
class TTSCall:
    """Args of a single ``text_to_speech`` tool call the agent made.

    Captured from the ``function_call`` item when it lands on the SSE
    stream so the runner can pair the spoken text with the eventual
    ``function_call_output`` result via ``call_id``.
    """

    call_id: str
    text: str
    voice: str | None = None
    output_path: str | None = None


@dataclass
class TTSResult:
    """Successful ``text_to_speech`` tool output ready to be uploaded.

    Only emitted for ``success: true`` results that include a non-empty
    ``file_path``. Failures fall through to the regular tool_result path
    so the agent still sees the error in its activity log.
    """

    call_id: str
    file_path: str
    provider: str | None = None
    voice_compatible: bool = False


@dataclass
class Translated:
    """Effect of one Hermes event on our DB."""
    step_kind: Literal[
        "thought",
        "tool_started",
        "tool_result",
        "oauth_needed",
        "input_needed",
        "final",
        "error",
    ] | None = None
    text: str | None = None
    url: str | None = None
    tool_name: str | None = None
    new_status: Literal[
        "running", "needs_auth", "needs_input", "done", "failed"
    ] | None = None
    final_text: str | None = None  # accumulated assistant final text
    interaction: InteractionRequest | None = None
    artifacts: list[ArtifactRequest] = field(default_factory=list)
    spawned_tasks: list[SpawnedTaskRequest] = field(default_factory=list)
    # Surfaced when this event is a TTS tool call (started) or its
    # successful output. The runner stitches the two together by
    # ``call_id`` and uploads the generated file to Supabase Storage,
    # then writes an ``audio`` artifact row. Neither is set on most
    # events.
    tts_call: TTSCall | None = None
    tts_result: TTSResult | None = None
    # Cumulative token total reported by this event for the *current* turn /
    # run. The runner derives a delta from successive values and increments
    # `todos.total_tokens` atomically. Zero means "no usage info on this
    # event" — events without a `usage` block leave this at 0 and the runner
    # ignores them.
    usage_total: int = 0


_CONNECTION_TOOL_HINTS = ("connect", "composio_manage_connections", "composio_wait")


def extract_usage_total(blob: Any) -> int:
    """Pull a single token total out of a Hermes/OpenAI `usage` blob.

    Hermes' Runs API normalizes to ``input_tokens`` / ``output_tokens`` /
    ``total_tokens``, but Chat-Completions-style chunks use the legacy
    ``prompt_tokens`` / ``completion_tokens`` / ``total_tokens`` shape. We
    accept either and fall back to the sum if ``total_tokens`` is missing.
    """
    if not isinstance(blob, dict):
        return 0
    total = blob.get("total_tokens")
    if isinstance(total, int) and total >= 0:
        return total
    inp = blob.get("input_tokens", blob.get("prompt_tokens"))
    out = blob.get("output_tokens", blob.get("completion_tokens"))
    inp_i = int(inp) if isinstance(inp, (int, float)) else 0
    out_i = int(out) if isinstance(out, (int, float)) else 0
    return max(0, inp_i + out_i)


def _looks_like_oauth_url(text: str, tool_name: str | None) -> str | None:
    """If this tool output contains an OAuth URL the user should open, return it."""
    if not text:
        return None
    tn = (tool_name or "").lower()
    is_connection_tool = any(h in tn for h in _CONNECTION_TOOL_HINTS)
    # Be conservative: only treat as OAuth if it came from a connection-y tool,
    # OR the text explicitly says "authorize" / "connect".
    lower = text.lower()
    signals = (
        "authorize",
        "authorization url",
        "connect your",
        "please visit",
        "click the following link",
    )
    if not (is_connection_tool or any(s in lower for s in signals)):
        return None
    m = _OAUTH_URL_RE.search(text)
    return m.group(0) if m else None


def extract_terminal_text(event_name: str, data: dict) -> str | None:
    """Return the assistant's final reply text if this event terminates the run.

    Used by the preparation pass, which only cares about the final structured
    JSON block (no tool calls, no streaming deltas). Returns ``None`` for
    every non-terminal event.
    """
    actual_event = str(data.get("event") or event_name or "")
    if actual_event == "run.completed":
        return str(data.get("output") or "").strip()
    if actual_event == "response.completed":
        resp = data.get("response") or {}
        return _extract_final_text(resp).strip()
    if actual_event in ("done", "message", "") and data.get("choices"):
        choice = (data.get("choices") or [{}])[0]
        if choice.get("finish_reason") in ("stop", "length"):
            msg = (choice.get("message") or {}).get("content") or ""
            return str(msg).strip()
    return None


def translate(event_name: str, data: dict) -> Translated | None:
    """Map one Hermes SSE event to a Translated effect, or None to skip."""
    actual_event = str(data.get("event") or event_name or "")

    # ----- Hermes run API lifecycle/tool events -----
    if actual_event == "tool.started":
        tool_name = data.get("tool") or data.get("name")
        preview = data.get("preview")
        friendly = _friendly_tool_label(str(tool_name) if tool_name else None)
        text = friendly + "." if friendly else f"Using {tool_name}."
        if preview:
            text = f"{text} {preview}"
        tts_call = None
        if str(tool_name or "") == TTS_TOOL_NAME and isinstance(preview, str):
            spoken = preview.strip()
            if spoken:
                tts_call = TTSCall(call_id="hermes-lifecycle", text=spoken)
        return Translated(
            step_kind="tool_started",
            text=text,
            tool_name=str(tool_name) if tool_name else None,
            tts_call=tts_call,
        )

    if actual_event == "tool.completed":
        tool_name = data.get("tool") or data.get("name")
        is_error = bool(data.get("error"))
        duration = data.get("duration")
        friendly_result = _friendly_tool_result_label(
            str(tool_name) if tool_name else None,
            is_error,
        )
        if friendly_result is not None:
            text = friendly_result
        else:
            # A tool can fail while the agent is still recovering and choosing a
            # different path. Treat this as a tool result, not a run-level error;
            # only explicit run/response failures below flip the todo to failed.
            text = "Tool hit an issue." if is_error else "Tool completed."
        if isinstance(duration, (int, float)):
            text = f"{text} ({duration:.1f}s)"
        return Translated(
            step_kind="tool_result",
            text=text,
            tool_name=str(tool_name) if tool_name else None,
        )

    if actual_event == "reasoning.available":
        text = str(data.get("text") or "").strip()
        activity = parse_activity(text)
        if activity:
            return Translated(step_kind="thought", text=activity)
        if (
            INTERACTION_OPEN in text
            or INTERACTION_CLOSE in text
            or ARTIFACT_OPEN in text
            or ARTIFACT_CLOSE in text
            or ACTIVITY_OPEN in text
            or ACTIVITY_CLOSE in text
        ):
            return None
        activity = parse_public_reasoning(text)
        if activity:
            return Translated(step_kind="thought", text=activity)

    if actual_event == "run.completed":
        text = str(data.get("output") or "").strip()
        usage_total = extract_usage_total(data.get("usage"))
        if not text:
            # Some providers emit a run-level completion event as lifecycle
            # bookkeeping before (or instead of) a final assistant message.
            # Treating that empty event as "Done." can race ahead of the real
            # final that contains artifacts, such as a newly-created Sheet
            # link. Keep the token accounting, but do not terminate here.
            return Translated(usage_total=usage_total)
        result = _final_or_interaction(text)
        result.usage_total = usage_total
        return result

    # ----- tool start (Hermes-custom event on Chat Completions stream) -----
    if actual_event == "hermes.tool.progress":
        tool_name = data.get("tool") or data.get("name")
        message = data.get("message") or data.get("title") or "Working..."
        return Translated(
            step_kind="tool_started",
            text=str(message),
            tool_name=str(tool_name) if tool_name else None,
        )

    # ----- Responses-API style output items -----
    if actual_event in ("response.output_item.added", "response.output_item.done"):
        item = data.get("item") or {}
        itype = item.get("type")
        if itype == "function_call" and actual_event == "response.output_item.added":
            name = str(item.get("name") or "")
            if name == TTS_TOOL_NAME:
                tts_call = _parse_tts_call(item)
                if tts_call is not None:
                    return Translated(
                        step_kind="tool_started",
                        text="Generating spoken summary.",
                        tool_name=name,
                        tts_call=tts_call,
                    )
            friendly = _friendly_tool_label(name)
            if friendly is not None:
                summary = _summarize_memory_call(name, item)
                text = f"{friendly}: {summary}" if summary else friendly + "."
                return Translated(
                    step_kind="tool_started",
                    text=text,
                    tool_name=name,
                )
            return Translated(
                step_kind="tool_started",
                text=_summarize_tool_call(item),
                tool_name=name,
            )
        if itype == "function_call_output" and actual_event == "response.output_item.done":
            output = item.get("output")
            text = _stringify_output(output)
            call_id = str(item.get("call_id") or "")
            tool_name = str(item.get("name") or call_id or "")
            tts_result = _parse_tts_result(call_id, output)
            if tts_result is not None:
                return Translated(
                    step_kind="tool_result",
                    text="Spoken summary ready.",
                    tool_name=tool_name or TTS_TOOL_NAME,
                    tts_result=tts_result,
                )
            oauth_url = _looks_like_oauth_url(text, tool_name)
            if oauth_url:
                return Translated(
                    step_kind="oauth_needed",
                    text="Connect an account to continue.",
                    url=oauth_url,
                    tool_name=tool_name,
                    new_status="needs_auth",
                )
            return Translated(
                step_kind="tool_result",
                text=_truncate(text, 600),
                tool_name=tool_name,
            )

    # ----- final assistant text (Responses style) -----
    if actual_event == "response.completed":
        resp = data.get("response") or {}
        text = _extract_final_text(resp)
        usage_total = extract_usage_total(resp.get("usage"))
        if not text:
            # Tool-call-only response turns can complete with no assistant
            # message. The runner should keep waiting for the follow-up final
            # text/artifact event instead of closing the task with "Done.".
            return Translated(usage_total=usage_total)
        result = _final_or_interaction(text)
        # Hermes fires `response.completed` once per LLM turn, so this is
        # the main live source of usage during a multi-tool-call run.
        result.usage_total = usage_total
        return result

    # ----- chat.completions style final -----
    if actual_event in ("done", "message", "") and data.get("choices"):
        choice = (data.get("choices") or [{}])[0]
        finish = choice.get("finish_reason")
        if finish in ("stop", "length"):
            msg = (choice.get("message") or {}).get("content") or ""
            result = _final_or_interaction(msg)
            result.usage_total = extract_usage_total(data.get("usage"))
            return result

    # ----- explicit run lifecycle -----
    if actual_event in ("run.failed", "response.failed", "error"):
        msg = data.get("error") or data.get("message") or "The run failed."
        return Translated(step_kind="error", text=str(msg), new_status="failed")

    return None


def _final_or_interaction(text: str) -> Translated:
    """Decide whether a model "final" reply is actually an ask-the-user pause."""
    text = (text or "").strip()
    interaction = parse_interaction(text)
    if interaction is not None:
        # Interaction takes precedence: the agent is pausing, not delivering.
        # Any artifact blocks in the same reply are ignored — the agent
        # should re-emit them with its real final reply once the user
        # answers.
        prompt = interaction.prompt or "The agent needs your input."
        return Translated(
            step_kind="input_needed",
            text=_truncate(prompt, 600),
            new_status="needs_input",
            final_text=text,
            interaction=interaction,
        )
    # Real final: parse artifacts and spawn-task blocks out of the reply.
    artifacts = parse_artifacts(text)
    spawned_tasks = parse_spawned_tasks(text)
    visible = normalize_visible_reply(strip_activity(strip_tasks(strip_artifacts(text))))
    return Translated(
        step_kind="final",
        text=_truncate(visible, 2000) if visible else "Done.",
        new_status="done",
        final_text=text,
        artifacts=artifacts,
        spawned_tasks=spawned_tasks,
    )


def parse_interaction(text: str) -> InteractionRequest | None:
    """Extract a structured interaction request from the model's final reply.

    The model is instructed to wrap one JSON object between the
    INTERACTION_OPEN / INTERACTION_CLOSE markers. Anything outside the block is
    treated as commentary and dropped before we hand it to the activity log.
    """
    if not text:
        return None
    match = _INTERACTION_RE.search(text)
    if not match:
        return None
    raw_json = match.group(1)
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError as e:
        log.warning("interaction block JSON parse failed: %s", e)
        return None
    if not isinstance(data, dict):
        return None

    raw_kind = str(data.get("kind") or "").strip().lower()
    if raw_kind not in {"approval", "choice", "question", "confirmation"}:
        # Fall back to a safe default rather than dropping the ask entirely.
        raw_kind = "question"

    prompt = str(data.get("prompt") or "").strip()
    if not prompt:
        prompt = str(data.get("summary") or "").strip() or "Need your input."

    payload: dict[str, Any] = {}
    for key in ("summary", "content", "options", "allow_freeform",
                "freeform_placeholder"):
        if key in data:
            payload[key] = data[key]

    options = payload.get("options")
    if isinstance(options, list):
        payload["options"] = [_clean_option(o) for o in options if _clean_option(o)]
    elif options is not None:
        payload.pop("options", None)

    return InteractionRequest(kind=raw_kind, prompt=prompt[:500], payload=payload)


def parse_activity(text: str) -> str | None:
    """Extract one public progress update from a DOIT_ACTIVITY block.

    The model is instructed to keep this short and user-facing. The parser
    still trims and rejects obvious non-copy so a malformed marker cannot
    become a noisy status line.
    """
    if not text:
        return None
    match = _ACTIVITY_RE.search(text)
    if not match:
        return None
    value = normalize_visible_reply(match.group(1))
    if not value:
        return None
    if any(marker in value for marker in (
        INTERACTION_OPEN,
        INTERACTION_CLOSE,
        ARTIFACT_OPEN,
        ARTIFACT_CLOSE,
        TASKS_OPEN,
        TASKS_CLOSE,
        ACTIVITY_OPEN,
        ACTIVITY_CLOSE,
    )):
        return None
    value = " ".join(value.split())
    if len(value) > 120:
        value = value[:119].rstrip() + "…"
    return value


def parse_public_reasoning(text: str) -> str | None:
    """Extract a safe public status line from upstream reasoning text.

    Hermes sometimes emits `reasoning.available` with useful prose like
    "Looking through the Figma file now." When it instead contains raw
    structured/tool/code output, we drop it and let tool events or the
    heartbeat drive the UI.
    """
    if not text:
        return None
    if any(marker in text for marker in (
        INTERACTION_OPEN,
        INTERACTION_CLOSE,
        ARTIFACT_OPEN,
        ARTIFACT_CLOSE,
        TASKS_OPEN,
        TASKS_CLOSE,
        ACTIVITY_OPEN,
        ACTIVITY_CLOSE,
    )):
        return None
    value = normalize_visible_reply(text)
    if not value:
        return None
    value = " ".join(value.split())
    if not _looks_like_public_activity(value):
        return None
    return _first_public_activity_sentence(value)


def _looks_like_public_activity(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < 8:
        return False
    if len(stripped.split()) < 3:
        return False
    if stripped.startswith(("```", "{", "}", "[", "]", "<", ">")):
        return False
    if any(ch in stripped for ch in ("\x00", "\r")):
        return False
    lower = stripped.lower()
    if lower in {"tool completed.", "tool completed", "thinking", "thinking..."}:
        return False
    if lower.startswith(("tool completed", "tool hit an issue", "error:", "traceback")):
        return False
    if any(pattern.search(stripped) for pattern in _NOISY_ACTIVITY_PATTERNS):
        return False
    # Reject dense structured blobs and code-like snippets while still
    # allowing normal punctuation in short prose.
    symbolic = sum(1 for ch in stripped if ch in "{}[]<>`$=|\\")
    if symbolic >= 3:
        return False
    if stripped.count(":") >= 3 or stripped.count(",") >= 6:
        return False
    return True


def _first_public_activity_sentence(text: str) -> str:
    for sep in (". ", "! ", "? ", "\n", "; "):
        idx = text.find(sep)
        if 0 < idx < 180:
            return text[: idx + 1].strip()
    return _truncate(text, 180)


def strip_activity(text: str) -> str:
    """Remove every public activity marker block from visible assistant text."""
    if not text:
        return text
    return _ACTIVITY_RE.sub("", text)


def parse_artifacts(text: str) -> list[ArtifactRequest]:
    """Extract every ``[[DOIT_ARTIFACT]]`` block from the model's final reply.

    Each block must be a single JSON object with at least ``type`` (one of
    the renderable kinds). ``key`` is optional and defaults to ``type`` so
    a single-artifact reply doesn't require the agent to invent an id;
    follow-up replies that want to update an artifact must supply the same
    ``key`` to hit the ``(todo_id, artifact_key)`` upsert key.

    Malformed blocks (bad JSON, unknown ``type``, non-object) are skipped
    rather than raising — surfacing nothing is friendlier than crashing the
    run because the model added an extra comma.
    """
    if not text:
        return []
    out: list[ArtifactRequest] = []
    seen_keys: set[str] = set()
    for raw_body in _ARTIFACT_RE.findall(text):
        try:
            data = json.loads(raw_body.strip())
        except json.JSONDecodeError as e:
            log.warning("artifact block JSON parse failed: %s", e)
            continue
        if not isinstance(data, dict):
            continue
        kind = str(data.get("type") or data.get("kind") or "").strip().lower()
        if kind not in _ARTIFACT_KINDS:
            log.warning("artifact block has unknown type=%r; skipping", kind)
            continue
        key = str(data.get("key") or kind).strip()[:64] or kind
        title_raw = data.get("title")
        title = str(title_raw).strip()[:200] if title_raw else None
        payload_raw = data.get("payload")
        payload = payload_raw if isinstance(payload_raw, dict) else {}
        # Deduplicate within one reply on the same key: the agent gets one
        # row per key per turn; later blocks win, matching the upsert
        # semantics in `db.upsert_artifact`.
        if key in seen_keys:
            for i, existing in enumerate(out):
                if existing.key == key:
                    out[i] = ArtifactRequest(
                        key=key, kind=kind, title=title, payload=payload
                    )
                    break
            continue
        seen_keys.add(key)
        out.append(
            ArtifactRequest(key=key, kind=kind, title=title, payload=payload)
        )
    return out


def strip_artifacts(text: str) -> str:
    """Remove every ``[[DOIT_ARTIFACT]] … [[/DOIT_ARTIFACT]]`` block from text.

    Used to keep the displayed ``final`` step free of raw JSON. The
    enclosing markers are dropped along with the JSON body; surrounding
    whitespace is left to the caller to trim.
    """
    if not text:
        return text
    return _ARTIFACT_RE.sub("", text)


def parse_spawned_tasks(text: str) -> list[SpawnedTaskRequest]:
    """Extract ``[[DOIT_TASKS]]`` blocks from the model's final reply."""
    if not text:
        return []
    match = _TASKS_RE.search(text)
    if not match:
        return []
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError as e:
        log.warning("spawned tasks JSON parse failed: %s", e)
        return []
    if not isinstance(data, dict):
        return []
    raw_tasks = data.get("tasks")
    if not isinstance(raw_tasks, list):
        return []

    out: list[SpawnedTaskRequest] = []
    seen_keys: set[str] = set()
    seen_titles: set[str] = set()
    for item in raw_tasks:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or "").strip()
        source_key = str(item.get("source_key") or "").strip()
        if not title or not source_key:
            log.warning("spawned task missing title or source_key; skipping")
            continue
        if source_key in seen_keys:
            continue
        # Some model replies accidentally duplicate the same task title with
        # two different source_keys in one block; keep the first.
        title_norm = " ".join(title.lower().split())
        if title_norm in seen_titles:
            log.warning("spawned task duplicate title=%r; skipping", title)
            continue
        seen_keys.add(source_key)
        seen_titles.add(title_norm)
        detail_raw = item.get("detail")
        detail = str(detail_raw).strip()[:4000] if detail_raw else None
        summary_raw = item.get("summary")
        summary = str(summary_raw).strip()[:400] if summary_raw else None
        slug_raw = item.get("connection_slug")
        slug = str(slug_raw).strip().lower()[:64] if slug_raw else None
        out.append(
            SpawnedTaskRequest(
                title=title[:200],
                source_key=source_key[:120],
                detail=detail,
                connection_slug=slug,
                summary=summary,
            )
        )
    return out


def strip_tasks(text: str) -> str:
    """Remove ``[[DOIT_TASKS]]`` blocks from visible final text."""
    if not text:
        return text
    return _TASKS_RE.sub("", text)


def collapse_done_leadins(text: str) -> str:
    """Fold repeated ``Done —`` openings into one closing paragraph.

    Models often emit one ``Done —`` sentence when surfacing an artifact
    link, then another ``Done —`` block for the human summary. The chat
    should read as a single reply.
    """
    stripped = (text or "").strip()
    if not stripped:
        return ""
    chunks = re.split(
        r"\n\s*\n(?=Done\s*[—\-]\s*)",
        stripped,
        flags=re.IGNORECASE,
    )
    if len(chunks) <= 1:
        return stripped
    head = chunks[0].strip()
    tail_parts: list[str] = []
    lead_re = re.compile(r"^Done\s*[—\-]\s*", re.IGNORECASE)
    for chunk in chunks[1:]:
        piece = lead_re.sub("", chunk.strip(), count=1).strip()
        if piece:
            tail_parts.append(piece)
    if not tail_parts:
        return head
    return f"{head}\n\n" + "\n\n".join(tail_parts)


def normalize_visible_reply(text: str) -> str:
    """Tidy chat-visible agent text after stripping structured blocks.

    Artifact / task / interaction markers are removed by ``strip_*`` helpers,
    but multi-line JSON blocks often leave several consecutive blank lines.
    The iOS chat renders those as large vertical gaps — especially between
    inline URLs and the closing paragraph that followed the artifact blocks.
    """
    if not text:
        return ""
    cleaned = text
    for marker in (
        ARTIFACT_OPEN,
        ARTIFACT_CLOSE,
        INTERACTION_OPEN,
        INTERACTION_CLOSE,
        TASKS_OPEN,
        TASKS_CLOSE,
        ACTIVITY_OPEN,
        ACTIVITY_CLOSE,
    ):
        cleaned = cleaned.replace(marker, "")
    cleaned = re.sub(r"[ \t]+\n", "\n", cleaned)
    cleaned = re.sub(r"\n[ \t]+", "\n", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    cleaned = collapse_done_leadins(cleaned.strip())
    return cleaned.strip()


def merge_terminal_translated(
    prior: Translated | None, new: Translated
) -> Translated:
    """Merge multiple terminal completions from one Hermes run.

    Hermes may emit more than one ``response.completed`` / ``run.completed``
    with assistant text (for example a short artifact line plus a longer
    summary). The runner drains the stream and persists a single ``final``
    chat row.
    """
    if prior is None:
        return new
    prior_raw = (prior.final_text or prior.text or "").strip()
    new_raw = (new.final_text or new.text or "").strip()
    if not prior_raw:
        return new
    if not new_raw or new_raw in prior_raw:
        combined_raw = prior_raw
    elif prior_raw in new_raw:
        combined_raw = new_raw
    else:
        combined_raw = f"{prior_raw}\n\n{new_raw}"
    artifacts = parse_artifacts(combined_raw)
    spawned_tasks = parse_spawned_tasks(combined_raw)
    visible = normalize_visible_reply(strip_tasks(strip_artifacts(combined_raw)))
    return Translated(
        step_kind="final",
        text=_truncate(visible, 2000) if visible else "Done.",
        new_status="done",
        final_text=combined_raw,
        artifacts=artifacts,
        spawned_tasks=spawned_tasks,
        usage_total=max(prior.usage_total, new.usage_total),
    )


def _clean_option(option: Any) -> dict[str, Any] | None:
    if not isinstance(option, dict):
        return None
    opt_id = str(option.get("id") or "").strip()
    label = str(option.get("label") or opt_id).strip()
    if not opt_id or not label:
        return None
    cleaned: dict[str, Any] = {"id": opt_id[:64], "label": label[:80]}
    style = str(option.get("style") or "").strip().lower()
    if style in {"primary", "secondary", "destructive"}:
        cleaned["style"] = style
    return cleaned


def _summarize_tool_call(item: dict) -> str:
    name = item.get("name") or "tool"
    args = item.get("arguments")
    if isinstance(args, str) and args:
        return f"{name}({_truncate(args, 200)})"
    return f"{name}(...)"


def _summarize_memory_call(name: str, item: dict) -> str:
    """Short, human-readable summary of a memory or session_search call.

    For the ``memory`` tool we surface the action (add/replace/remove) and
    a snippet of the entry. For ``session_search`` we surface the query.
    Bad or empty arguments fall through to an empty string so the caller
    keeps the default friendly label.
    """
    args = item.get("arguments")
    parsed: dict[str, Any] = {}
    if isinstance(args, str) and args.strip():
        try:
            parsed = json.loads(args)
        except json.JSONDecodeError:
            return ""
    elif isinstance(args, dict):
        parsed = args
    if not isinstance(parsed, dict):
        return ""
    lower = name.lower()
    if lower in _SESSION_SEARCH_TOOL_NAMES:
        query = str(parsed.get("query") or parsed.get("q") or "").strip()
        return _truncate(query, 120) if query else ""
    if lower in _MEMORY_TOOL_NAMES:
        action = str(parsed.get("action") or parsed.get("op") or "").strip().lower()
        text = (
            parsed.get("text")
            or parsed.get("entry")
            or parsed.get("content")
            or parsed.get("value")
            or ""
        )
        snippet = _truncate(str(text).strip(), 80)
        if action and snippet:
            return f"{action}: {snippet}"
        return snippet or action
    return ""


def _parse_tts_call(item: dict) -> TTSCall | None:
    """Pull the spoken text + optional voice/output_path out of a TTS call.

    Returns ``None`` when the arguments are malformed or empty so the
    surrounding ``translate`` branch can fall through to the generic
    tool_started rendering instead of pretending we captured a TTS call.
    """
    call_id = str(item.get("call_id") or "")
    args = item.get("arguments")
    parsed: dict[str, Any] = {}
    if isinstance(args, str) and args.strip():
        try:
            parsed = json.loads(args)
        except json.JSONDecodeError:
            return None
    elif isinstance(args, dict):
        parsed = args
    if not isinstance(parsed, dict):
        return None
    text = str(parsed.get("text") or "").strip()
    if not text:
        return None
    voice_raw = parsed.get("voice")
    voice = str(voice_raw).strip() if voice_raw else None
    out_raw = parsed.get("output_path")
    output_path = str(out_raw).strip() if out_raw else None
    return TTSCall(
        call_id=call_id,
        text=text,
        voice=voice or None,
        output_path=output_path or None,
    )


def _parse_tts_result(call_id: str, output: Any) -> TTSResult | None:
    """Return a TTSResult only for successful TTS tool outputs.

    The Hermes ``text_to_speech`` tool returns a JSON string shaped like
    ``{"success": true, "file_path": "...", "provider": "elevenlabs", ...}``.
    Failures and non-TTS outputs short-circuit so the regular
    ``tool_result`` path keeps surfacing them in the activity log.
    """
    parsed: dict[str, Any] | None = None
    if isinstance(output, str) and output.strip():
        try:
            parsed = json.loads(output)
        except json.JSONDecodeError:
            return None
    elif isinstance(output, dict):
        parsed = output
    if not isinstance(parsed, dict):
        return None
    if parsed.get("success") is not True:
        return None
    file_path = parsed.get("file_path")
    if not isinstance(file_path, str) or not file_path.strip():
        return None
    provider_raw = parsed.get("provider")
    provider = str(provider_raw).strip() if provider_raw else None
    return TTSResult(
        call_id=call_id,
        file_path=file_path.strip(),
        provider=provider or None,
        voice_compatible=bool(parsed.get("voice_compatible", False)),
    )


def _stringify_output(output) -> str:
    if output is None:
        return ""
    if isinstance(output, str):
        return output
    if isinstance(output, dict):
        return str(output.get("text") or output.get("content") or output)
    return str(output)


def _extract_final_text(resp: dict) -> str:
    out = resp.get("output") or []
    parts: list[str] = []
    for item in out:
        if item.get("type") != "message":
            continue
        for c in item.get("content") or []:
            if c.get("type") == "output_text":
                parts.append(c.get("text") or "")
    return "\n".join(p for p in parts if p)


def _truncate(text: str, limit: int) -> str:
    text = text or ""
    return text if len(text) <= limit else text[: limit - 1] + "\u2026"
