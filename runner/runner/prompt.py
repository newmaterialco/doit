"""Pure helpers for building Hermes /v1/runs inputs.

Kept in its own leaf module so tests can import it without bringing in
Supabase or httpx. The runner imports the same helpers.

The key contracts this module encodes:

  * Each todo gets its OWN Hermes ``session_id`` so USER.md / MEMORY.md
    are reloaded as a fresh frozen snapshot for every run. Cross-todo
    recall still works: ``session_search`` is FTS5 over every prior
    session in the same profile, and the memory files persist regardless
    of which session_id is active.
  * A stable per-user ``session_key`` (sent as ``X-Hermes-Session-Key``)
    is what an eventual external memory provider (Honcho, Mem0, …) would
    use to scope long-term memory to a Doit user. Built-in memory is
    already per-profile so the key is future-proofing today.
  * Per-todo input no longer enumerates the user's memories — Hermes loads
    them from the frozen snapshot at session start.
"""
from __future__ import annotations

import json
from typing import Any


def session_id_for_todo(user_id: str, todo_id: str) -> str:
    """Per-todo execution session id.

    Hermes loads USER.md / MEMORY.md as a frozen snapshot at session start
    and never refreshes it mid-session (the docs are explicit about this).
    Using a fresh session_id per todo guarantees the next run sees any
    pinned memory the runner just wrote, plus anything the agent saved on
    the previous turn via its ``memory`` tool.
    """
    return f"doit-todo-{todo_id}"


def prep_session_id_for_todo(todo_id: str) -> str:
    """Per-todo preparation session id.

    Prep runs use a tightly scoped system prompt (no tools, JSON only).
    Giving each todo its own prep session keeps the conversation clean and
    matches the per-todo execution session, so the model isn't surprised
    by leftover prep turns from another task.
    """
    return f"doit-prep-{todo_id}"


def session_key_for_user(user_id: str) -> str:
    """Stable per-user ``X-Hermes-Session-Key``.

    Hermes uses this to scope long-term memory providers (Honcho, Mem0,
    Supermemory, …) independently of the transcript-scoped session_id.
    Built-in MEMORY.md / USER.md are per-profile and don't need this, so
    today it just means "if/when we plug in an external provider, the
    user's memory pool is isolated from everyone else's".
    """
    return f"doit-user:{user_id}"


def build_prompt(
    title: str,
    detail: str,
    *,
    original_title: str | None = None,
    preparation_summary: str | None = None,
    connection_slug: str | None = None,
    attachment_urls: list[str] | None = None,
    pinned_memories: list[dict] | None = None,
) -> str:
    """Per-todo task prompt. Memory comes from Hermes' frozen snapshot.

    The prepared title is display metadata; the original user request is the
    source of truth for execution because it often contains concrete details
    (emails, dates, names) that do not fit cleanly in a compact card title.

    ``attachment_urls`` are short-lived signed URLs to images the user
    attached to the todo. They are appended verbatim so Hermes' built-in
    ``vision_analyze`` tool can fetch the pixels on demand.

    ``pinned_memories`` are user-authored entries the runner just staged
    into USER.md / MEMORY.md. They are also surfaced in the prompt as a
    short instruction so the agent calls its ``memory`` tool to confirm /
    consolidate them properly, rather than leaving the file write to be
    the only mechanism. See ``_append_pinned_memory_block``.
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
    base = _append_pinned_memory_block(base, pinned_memories)
    base = _append_artifacts_instructions(base)
    base = _append_approval_instructions(base)
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
    pinned_memories: list[dict] | None = None,
    task_context: dict[str, list[dict]] | None = None,
) -> str:
    """Follow-up prompt with the user's interaction response woven in."""
    base = build_prompt(
        title,
        detail,
        original_title=original_title,
        preparation_summary=preparation_summary,
        connection_slug=connection_slug,
        pinned_memories=pinned_memories,
    )
    base = _append_task_context_block(base, task_context)

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
- Use exactly one "Done —" lead-in per final reply. Summarize every
  deliverable in the prose that follows; do not open a second "Done —"
  paragraph for the same turn (artifact links already appear as cards
  under the task title).
- Do not emit artifacts in the same reply as a [[DOIT_INTERACTION]] block;
  re-emit them once the user answers and the task actually finishes.

Spoken summaries (audio):
When the user asks for a summary, recap, digest, briefing, or "read this to
me", and the answer is at least a few sentences long, also call the
built-in ``text_to_speech`` tool with a concise spoken version of the
summary. The Doit runner intercepts that tool's output, uploads the
generated audio file, and surfaces it as an audio player at the top of
the task detail view with the spoken text shown beneath it.

Guidelines for ``text_to_speech``:
- Pass only the ``text`` argument; the user picks the provider/voice in
  their Hermes config (ElevenLabs, OpenAI TTS, Edge TTS, etc.). Do not
  set ``output_path`` — let the tool pick a path.
- Use the native tool named exactly ``text_to_speech``. Do not use
  Composio, browser uploads, storage/file-sharing tools, "audio
  recording" tools, or generated links for spoken summaries. Those show
  up as browser links in the app and are the wrong UX.
- The spoken text should read naturally out loud: drop markdown,
  bullet syntax, raw URLs, code blocks, and JSON. Use full sentences
  with light pacing. Keep it under ~400 words for a quick listen unless
  the user explicitly asked for the whole thing.
- Call ``text_to_speech`` once per task in your final turn (after any
  tool work has finished). Do not call it on every turn, and do not
  emit a separate ``[[DOIT_ARTIFACT]]`` block for the audio — the
  runner creates the artifact automatically from the tool result.
- Never emit a ``link`` artifact for audio. If you used
  ``text_to_speech`` correctly, the runner has the generated local file
  path and will create the in-app audio player automatically.
- Skip TTS for short replies (a single sentence, a confirmation,
  "Done.", a one-line answer) and for tasks where audio adds no value
  (sending an email, scheduling, writing a draft the user will read).
- Never put a ``MEDIA:`` tag or the raw file path in your chat reply —
  the audio player handles delivery.
"""


def _append_artifacts_instructions(base: str) -> str:
    """Teach the agent the artifact marker contract on every execution turn.

    Kept on the per-todo prompt (not the system prompt that lives in the
    Hermes profile) so the convention is self-contained in this repo and
    easy to evolve without redeploying profiles. Idempotent because the
    runner builds the prompt fresh each turn.
    """
    return base + _ARTIFACT_INSTRUCTIONS


def _append_pinned_memory_block(base: str, pinned: list[dict] | None) -> str:
    """Tell the agent about user-pinned memories so it can curate them.

    The runner already writes the pinned entries directly into USER.md /
    MEMORY.md before the run starts, so the frozen snapshot for THIS
    session already contains them. This block exists so the agent can
    apply its own judgment via the ``memory`` tool — deduping, replacing
    a stale older entry, splitting one entry across both files, or
    leaving the pin alone if it's already represented. This is the path
    the Hermes docs recommend ("the agent manages its own memory").
    """
    if not pinned:
        return base
    items: list[str] = []
    for row in pinned:
        target = (row.get("target") or "user").strip()
        title = (row.get("title") or "").strip()
        body = (row.get("body") or "").strip()
        if not (title or body):
            continue
        text = f"{title}: {body}" if title and body and title != body else body or title
        items.append(f"- target={target} :: {text}")
    if not items:
        return base
    lines = [
        "",
        "",
        "User-pinned memories (just added in the app):",
        "These entries were written into your USER.md / MEMORY.md before this "
        "session started, so they are already in your frozen memory snapshot. "
        "Use your `memory` tool to confirm/consolidate them — replace an older "
        "entry if it's now wrong, merge near-duplicates, or leave them alone "
        "if they are already represented. Do not echo them back to the user.",
    ]
    lines.extend(items)
    return base + "\n".join(lines)


_APPROVAL_INSTRUCTIONS = """\

Approval policy (draft first, ask second):
The Doit `+` sheet now auto-runs every prepared task — there is no
"Do it" tap in front of execution. To keep the user in the loop on
externally visible actions while still being useful, follow these
rules:

- Default to acting without asking for approval when the task is to
  CREATE something locally or in the user's own workspace: spreadsheets,
  Google Docs, Drive files, internal drafts, Notion pages, scratch
  notes, or links you'll surface as artifacts. Just do the work and
  emit the corresponding `[[DOIT_ARTIFACT]]` block.

- ALWAYS draft before asking. Do not stop at "Should I send X?" before
  you've produced the actual content. The approval card is meaningless
  without a draft to approve.

- Approval IS required (after drafting) before any of these actions:
  * sending an email,
  * sending or updating a calendar / meeting invite that includes
    attendees other than the user,
  * posting a public message (Slack channel, GitHub comment on a
    public repo, social media),
  * irreversibly modifying or deleting data the user did not explicitly
    ask to delete this turn.
  In each case, draft the email / invite / message first, then emit
  one `[[DOIT_INTERACTION]]` block of kind `approval` with the draft
  in `content` so iOS can render the draft preview and Send / Edit
  buttons. Wait for the user's response before sending.

- Approval is NOT required for: creating spreadsheets, docs, drafts,
  or other artifacts the user can review at their leisure;
  read-only research, search, or summarisation; sending TTS audio
  back; emitting artifacts. If the user explicitly asked you to
  "review with me" or "ask before <action>", honour that and gate
  even otherwise-safe actions.

- Once approved, perform the action immediately and emit a final
  artifact (or refreshed artifact set) describing what was sent.
"""


def _append_approval_instructions(base: str) -> str:
    """Append the approval / draft-first policy to every execution prompt.

    Mirrors `_append_artifacts_instructions` so the convention stays
    self-contained in this repo and can evolve without reshipping the
    Hermes profile. The block is idempotent because the runner rebuilds
    the prompt each turn.
    """
    return base + _APPROVAL_INSTRUCTIONS


def build_followup_prompt(
    title: str,
    detail: str,
    *,
    messages: list[str],
    original_title: str | None = None,
    preparation_summary: str | None = None,
    connection_slug: str | None = None,
    attachment_urls: list[str] | None = None,
    pinned_memories: list[dict] | None = None,
    task_context: dict[str, list[dict]] | None = None,
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
        pinned_memories=pinned_memories,
    )
    base = _append_task_context_block(base, task_context)

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


def _append_task_context_block(
    base: str,
    context: dict[str, list[dict]] | None,
) -> str:
    """Append explicit same-task history for follow-up turns.

    Hermes sessions should provide transcript continuity, but Doit's task
    detail already stores the user's visible reality: chat messages, activity
    steps, and artifact cards. Follow-up prompts include a compact snapshot of
    that state so the agent can resolve phrases like "the first doc", "that
    sheet", or "the links above" even if the backend session transcript is
    incomplete or pruned.
    """
    if not context:
        return base

    artifacts = context.get("artifacts") or []
    messages = context.get("messages") or []
    steps = context.get("steps") or []
    if not (artifacts or messages or steps):
        return base

    lines = [
        "",
        "",
        "Previous context for this task:",
        "Use this as the authoritative visible task history. The user may refer "
        "to artifacts below as \"the doc\", \"the sheet\", \"the links\", "
        "\"the first one\", etc. Continue from this state; do not pretend you "
        "cannot see prior task outputs.",
    ]

    if artifacts:
        lines += ["", "Artifacts already created:"]
        for row in artifacts[-20:]:
            lines.append(_format_artifact_context(row))

    if messages:
        lines += ["", "Recent user chat messages:"]
        for row in messages[-20:]:
            body = _truncate_one_line(str(row.get("body") or ""), 500)
            if body:
                lines.append(f"- {body}")

    if steps:
        lines += ["", "Recent agent activity / results:"]
        for row in steps[-30:]:
            formatted = _format_step_context(row)
            if formatted:
                lines.append(formatted)

    return base + "\n".join(lines)


def _format_artifact_context(row: dict) -> str:
    kind = str(row.get("kind") or "artifact")
    key = str(row.get("artifact_key") or "")
    title = str(row.get("title") or key or kind)
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    label = f"- [{kind}] {title}"
    if key:
        label += f" (key={key})"
    if kind == "link":
        url = str(payload.get("url") or "").strip()
        provider = str(payload.get("provider") or "").strip()
        details = " ".join(x for x in (provider, url) if x)
        return f"{label}: {details}" if details else label
    if kind == "email":
        subject = str(payload.get("subject") or "").strip()
        to = payload.get("to")
        recipients = ", ".join(str(x) for x in to) if isinstance(to, list) else str(to or "")
        body = _truncate_one_line(str(payload.get("body") or ""), 300)
        details = "; ".join(x for x in (f"to={recipients}" if recipients else "", f"subject={subject}" if subject else "", body) if x)
        return f"{label}: {details}" if details else label
    if kind == "text":
        text = _truncate_one_line(str(payload.get("text") or ""), 500)
        return f"{label}: {text}" if text else label
    if kind == "calendar":
        details = _safe_json(payload)
        return f"{label}: {_truncate_one_line(details, 500)}" if details else label
    details = _safe_json(payload)
    return f"{label}: {_truncate_one_line(details, 500)}" if details else label


def _format_step_context(row: dict) -> str:
    kind = str(row.get("kind") or "")
    text = _truncate_one_line(str(row.get("text") or ""), 500)
    url = str(row.get("url") or "").strip()
    tool = str(row.get("tool_name") or "").strip()
    if not (text or url):
        return ""
    label = kind or "step"
    if tool:
        label += f"/{tool}"
    detail = text
    if url:
        detail = f"{detail} {url}".strip()
    return f"- {label}: {detail}"


def _truncate_one_line(text: str, limit: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


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
