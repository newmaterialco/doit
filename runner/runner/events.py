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

# Anything that smells like a Composio OAuth redirect URL the user must visit.
# Composio surfaces these via its connection meta-tools; the exact host varies
# by upstream provider, so we accept any HTTPS URL emitted by a connection tool.
_OAUTH_URL_RE = re.compile(r"https://[^\s'\"<>]+")

_INTERACTION_RE = re.compile(
    re.escape(INTERACTION_OPEN) + r"\s*(\{.*?\})\s*" + re.escape(INTERACTION_CLOSE),
    re.DOTALL,
)


@dataclass
class InteractionRequest:
    """Structured ask-the-user request parsed from the model's final reply."""
    kind: str
    prompt: str
    payload: dict[str, Any] = field(default_factory=dict)


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


_CONNECTION_TOOL_HINTS = ("connect", "composio_manage_connections", "composio_wait")


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
        text = f"Using {tool_name}."
        if preview:
            text = f"{text} {preview}"
        return Translated(
            step_kind="tool_started",
            text=text,
            tool_name=str(tool_name) if tool_name else None,
        )

    if actual_event == "tool.completed":
        tool_name = data.get("tool") or data.get("name")
        is_error = bool(data.get("error"))
        duration = data.get("duration")
        text = "Tool failed." if is_error else "Tool completed."
        if isinstance(duration, (int, float)):
            text = f"{text} ({duration:.1f}s)"
        return Translated(
            step_kind="error" if is_error else "tool_result",
            text=text,
            tool_name=str(tool_name) if tool_name else None,
        )

    if actual_event == "reasoning.available":
        text = str(data.get("text") or "").strip()
        if INTERACTION_OPEN in text or INTERACTION_CLOSE in text:
            return None
        if text:
            return Translated(step_kind="thought", text=_truncate(text, 1000))

    if actual_event == "run.completed":
        text = str(data.get("output") or "").strip()
        return _final_or_interaction(text)

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
            return Translated(
                step_kind="tool_started",
                text=_summarize_tool_call(item),
                tool_name=str(item.get("name") or ""),
            )
        if itype == "function_call_output" and actual_event == "response.output_item.done":
            output = item.get("output")
            text = _stringify_output(output)
            tool_name = str(item.get("name") or item.get("call_id") or "")
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
        return _final_or_interaction(text)

    # ----- chat.completions style final -----
    if actual_event in ("done", "message", "") and data.get("choices"):
        choice = (data.get("choices") or [{}])[0]
        finish = choice.get("finish_reason")
        if finish in ("stop", "length"):
            msg = (choice.get("message") or {}).get("content") or ""
            return _final_or_interaction(msg)

    # ----- explicit run lifecycle -----
    if actual_event in ("run.completed", "response.completed"):
        return Translated(step_kind="final", text="Done.", new_status="done")
    if actual_event in ("run.failed", "response.failed", "error"):
        msg = data.get("error") or data.get("message") or "The run failed."
        return Translated(step_kind="error", text=str(msg), new_status="failed")

    return None


def _final_or_interaction(text: str) -> Translated:
    """Decide whether a model "final" reply is actually an ask-the-user pause."""
    text = (text or "").strip()
    interaction = parse_interaction(text)
    if interaction is not None:
        prompt = interaction.prompt or "The agent needs your input."
        return Translated(
            step_kind="input_needed",
            text=_truncate(prompt, 600),
            new_status="needs_input",
            final_text=text,
            interaction=interaction,
        )
    return Translated(
        step_kind="final",
        text=_truncate(text, 2000) if text else "Done.",
        new_status="done",
        final_text=text,
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
