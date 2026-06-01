"""Pure helpers for building Hermes /v1/runs inputs.

Kept in its own leaf module so tests can import it without bringing in
Supabase or httpx. The runner imports the same helpers.

The key contract this module encodes:

  * Every todo for one user shares a stable Hermes ``session_id`` so the
    agent's USER.md / MEMORY.md and session_search span the whole user,
    not a single todo.
  * Per-todo input no longer enumerates the user's memories — Hermes loads
    them from the frozen snapshot at session start.
"""
from __future__ import annotations

import json
from typing import Any


def session_id_for_user(user_id: str) -> str:
    """Stable Hermes session id used across every todo for one user."""
    return f"doit-user-{user_id}"


def prep_session_id_for_user(user_id: str) -> str:
    """Separate session used for the preparation pass.

    Preparation runs use a tightly scoped system prompt (no tools, JSON
    only) and we don't want those one-shot prep turns polluting the main
    execution session's conversation history. Memory (USER.md / MEMORY.md)
    is per-profile, so the prep session still sees the same user facts.
    """
    return f"doit-prep-user-{user_id}"


def build_prompt(
    title: str,
    detail: str,
    *,
    original_title: str | None = None,
    preparation_summary: str | None = None,
    connection_slug: str | None = None,
    attachment_urls: list[str] | None = None,
) -> str:
    """Per-todo task prompt. Memory comes from Hermes' frozen snapshot.

    The prepared title is display metadata; the original user request is the
    source of truth for execution because it often contains concrete details
    (emails, dates, names) that do not fit cleanly in a compact card title.

    ``attachment_urls`` are short-lived signed URLs to images the user
    attached to the todo. They are appended verbatim so Hermes' built-in
    ``vision_analyze`` tool can fetch the pixels on demand.
    """
    raw = (original_title or "").strip()
    detail = detail.strip()
    lines = [
        "New todo task:",
        "",
        "Use the original user request as the source of truth. The prepared "
        "title/summary are only UI metadata and may omit important details.",
        "",
        "Original user request:",
        raw or title,
        "",
        "Prepared title:",
        title,
    ]
    if detail:
        lines += ["", "Additional detail:", detail]
    if preparation_summary:
        lines += ["", "Preparation summary:", preparation_summary.strip()]
    if connection_slug:
        lines += ["", "Expected connection/toolkit:", connection_slug.strip()]
    base = "\n".join(lines)
    base = _append_artifacts_instructions(base)
    return _append_attachments(base, attachment_urls)


def build_resume_prompt(
    *,
    title: str,
    detail: str,
    interaction: dict,
    original_title: str | None = None,
    preparation_summary: str | None = None,
    connection_slug: str | None = None,
    attachment_urls: list[str] | None = None,
) -> str:
    """Follow-up prompt with the user's interaction response woven in."""
    base = build_prompt(
        title,
        detail,
        original_title=original_title,
        preparation_summary=preparation_summary,
        connection_slug=connection_slug,
    )

    prompt_text = interaction.get("prompt") or ""
    payload = interaction.get("payload") or {}
    response = interaction.get("response") or {}
    option_id = str(response.get("option_id") or "").strip()
    freeform = str(response.get("text") or "").strip()

    chosen_label = option_id
    options = payload.get("options") or []
    if isinstance(options, list):
        for opt in options:
            if isinstance(opt, dict) and str(opt.get("id") or "") == option_id:
                chosen_label = str(opt.get("label") or option_id)
                break

    lines = [
        "You previously asked the user:",
        f'  "{prompt_text}"',
    ]
    payload_json = _safe_json(payload)
    if payload_json:
        lines.append("With this proposal payload:")
        lines.append(payload_json)
    lines.append("")
    if option_id:
        lines.append(f"The user chose: {chosen_label} (option_id={option_id}).")
    if freeform:
        lines.append(f"The user also wrote: {freeform}")
    lines.append("")
    lines.append(
        "Continue from where you left off. If the choice was approving the "
        "previous proposal, execute it now. If the user asked for a rewrite "
        "or clarification, produce a new proposal and ask again if needed. "
        "Do not ask the same question you already asked unless something "
        "materially changed."
    )
    composed = f"{base}\n\n" + "\n".join(lines)
    return _append_attachments(composed, attachment_urls)


_ARTIFACT_INSTRUCTIONS = """\

Artifacts (user-visible deliverables):
When this task produces something the user should see at a glance — a
created Google Sheet / Doc / Drive link, a sent email, a calendar invite,
or a short text result — include one or more artifact blocks in your
final reply. The Doit iOS app renders each block as a compact card under
the task title.

Format (one JSON object per block, wrapped exactly like this):

[[DOIT_ARTIFACT]]
{"key":"<stable id>","type":"link|email|calendar|text",
 "title":"<short label>","payload":{...}}
[[/DOIT_ARTIFACT]]

Payload shapes by type:
- link:     {"url":"https://...","provider":"googlesheets|googledocs|gmail|..."}
- email:    {"to":["a@b.com"],"subject":"...","body":"...",
             "provider":"gmail"}
- calendar: {"title":"...","start":"<ISO8601>","end":"<ISO8601>",
             "location":"...","attendees":["a@b.com"],"url":"https://..."}
- text:     {"text":"..."}

Rules:
- Use a stable ``key`` per artifact and reuse the same key in a later turn
  to update that card rather than creating a new one.
- Multi-step tasks should drill down in the UI: emit the primary deliverable
  first (e.g. key ``sheet`` with type ``link`` and provider ``googlesheets``),
  then emit one ``email`` artifact per draft with distinct keys such as
  ``email-acme``, ``email-beta``, … each with provider ``gmail``. On later
  turns, re-emit earlier artifacts plus any new ones so the header keeps
  the sheet and accumulates draft cards underneath.
- Do not collapse many drafts into one artifact or one long text block.
- Only emit artifacts for things the user actually wants to revisit. Skip
  intermediate search results, scratch notes, or tool diagnostics.
- The block must be valid JSON on its own. Do not wrap it in a code fence.
- Anything outside the markers stays in the chat reply as normal prose.
- Do not emit artifacts in the same reply as a [[DOIT_INTERACTION]] block;
  re-emit them once the user answers and the task actually finishes.
"""


def _append_artifacts_instructions(base: str) -> str:
    """Teach the agent the artifact marker contract on every execution turn.

    Kept on the per-todo prompt (not the system prompt that lives in the
    Hermes profile) so the convention is self-contained in this repo and
    easy to evolve without redeploying profiles. Idempotent because the
    runner builds the prompt fresh each turn.
    """
    return base + _ARTIFACT_INSTRUCTIONS


def build_followup_prompt(
    title: str,
    detail: str,
    *,
    messages: list[str],
    original_title: str | None = None,
    preparation_summary: str | None = None,
    connection_slug: str | None = None,
    attachment_urls: list[str] | None = None,
) -> str:
    """Resume prompt for plain user chat messages (no interaction card).

    Used when the user types in the detail view's composer after a previous
    turn finished (or failed, or paused on auth). The original task framing
    is preserved verbatim, then a short follow-up block quotes the new
    user messages and tells the agent to continue the same task.
    """
    base = build_prompt(
        title,
        detail,
        original_title=original_title,
        preparation_summary=preparation_summary,
        connection_slug=connection_slug,
    )

    quoted = [m.strip() for m in messages if m and m.strip()]
    if not quoted:
        # Fall back to the base prompt so we never ship an empty follow-up
        # block that would just confuse the model.
        return _append_attachments(base, attachment_urls)

    lines = ["The user sent a follow-up message about this task:"]
    for msg in quoted:
        for i, line in enumerate(msg.splitlines() or [""]):
            lines.append(f"  {'> ' if i == 0 else '  '}{line}")
    lines.append("")
    lines.append(
        "Continue from where you left off on the same task. Use this "
        "message as new direction from the user; if it asks a question, "
        "answer it; if it changes the goal, adapt; otherwise keep going. "
        "Do not restart from scratch."
    )
    composed = f"{base}\n\n" + "\n".join(lines)
    return _append_attachments(composed, attachment_urls)


def _append_attachments(base: str, attachment_urls: list[str] | None) -> str:
    """Append a stable ``Attachments (images):`` block at the end of a prompt.

    The block is only emitted when there is at least one URL. The agent's
    system prompt explains that this block is the canonical place to find
    images for the current task, and that it should call ``vision_analyze``
    on these URLs when the task requires looking at them.
    """
    if not attachment_urls:
        return base
    cleaned = [url.strip() for url in attachment_urls if url and url.strip()]
    if not cleaned:
        return base
    block = ["", "", "Attachments (images):"]
    block += [f"- {url}" for url in cleaned]
    block.append(
        "Call vision_analyze on these URLs only if the task requires "
        "looking at them."
    )
    return base + "\n".join(block)


def _safe_json(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, indent=2)
    except (TypeError, ValueError):
        return ""
