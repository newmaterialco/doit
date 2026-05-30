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


def build_prompt(title: str, detail: str) -> str:
    """Per-todo task prompt. Memory comes from Hermes' frozen snapshot."""
    task = f"{title}\n\n{detail}".strip() if detail else title
    return f"New todo task:\n{task}"


def build_resume_prompt(*, title: str, detail: str, interaction: dict) -> str:
    """Follow-up prompt with the user's interaction response woven in."""
    base = build_prompt(title, detail)

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
    return f"{base}\n\n" + "\n".join(lines)


def _safe_json(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, indent=2)
    except (TypeError, ValueError):
        return ""
