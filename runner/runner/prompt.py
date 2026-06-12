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
import os
import re
from typing import Any


# Matches the USER's own words asking for spoken audio. Deliberately checks
# user text (title/detail/original request), never the model's judgment of
# its own output — weaker models will happily decide a repo listing is a
# "summary" and call text_to_speech unprompted. Soft triggers (summary,
# recap, digest, briefing) stay in the predicate so genuine "summarize my
# inbox" tasks keep producing audio like they do today.
_SPOKEN_AUDIO_RE = re.compile(
    r"\b("
    r"read\s+(?:this|it|that)?\s*(?:aloud|out\s+loud|to\s+me)|"
    r"voice\s*memo|voice\s*note|spoken|audio|listen|podcast|tts|"
    r"text[\s-]*to[\s-]*speech|say\s+it\s+out\s+loud|out\s+loud|"
    r"summary|summarize|summarise|recap|digest|briefing|brief\s+me"
    r")\b",
    re.IGNORECASE,
)


def user_wants_spoken_audio(*texts: str | None) -> bool:
    """True when the user's own words ask for audio or a spoken summary.

    Used twice: to decide whether the TTS instructions are appended to the
    execution prompt at all, and as the runner-side guard that discards
    audio the agent generated for a task that never asked for it (e.g.
    "List the Github repos you have access to" → no audio words → any
    text_to_speech output is dropped).
    """
    for text in texts:
        if text and _SPOKEN_AUDIO_RE.search(text):
            return True
    return False


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
    topic: str | None = None,
    processed_attachment_urls: list[str] | None = None,
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
    task_text = "\n".join(x for x in (original_title, title, detail) if x)
    base = _append_artifacts_instructions(
        base,
        audio_requested=user_wants_spoken_audio(title, detail, original_title),
        connection_slug=connection_slug,
        topic=topic,
        task_text=task_text,
    )
    base = _append_activity_instructions(base)
    base = _append_approval_instructions(base)
    base = _append_recall_nudge(base, original_title, title, detail)
    return _append_attachments(
        base, attachment_urls, processed_urls=processed_attachment_urls
    )


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
    topic: str | None = None,
    processed_attachment_urls: list[str] | None = None,
) -> str:
    """Follow-up prompt with the user's interaction response woven in."""
    base = build_prompt(
        title,
        detail,
        original_title=original_title,
        preparation_summary=preparation_summary,
        connection_slug=connection_slug,
        pinned_memories=pinned_memories,
        topic=topic,
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
    approved_send = (
        str(interaction.get("kind") or "").lower() in {"approval", "confirmation"}
        and option_id.lower() in {"send", "yes", "approve", "confirm", "ok", "post"}
    )
    if approved_send:
        lines.append(
            "The user approved this outbound action on the card. You may now "
            "call send / calendar-invite / public-post tools to execute it, "
            "then emit the final artifact(s)."
        )
    lines.append(
        "Continue from where you left off. If the choice was approving the "
        "previous proposal, execute it now. If the user asked for a rewrite "
        "or clarification, produce a new proposal and ask again if needed. "
        "Do not ask the same question you already asked unless something "
        "materially changed."
    )
    composed = f"{base}\n\n" + "\n".join(lines)
    return _append_attachments(
        composed, attachment_urls, processed_urls=processed_attachment_urls
    )


# Legacy (pre-compaction) core artifact prose. Restored instantly by
# setting DOIT_COMPACT_PROMPTS=0 — no deploy needed.
_ARTIFACT_CORE_LEGACY = """\

Artifacts (user-visible deliverables):
When this task produces something the user should see at a glance — a
created Google Sheet / Doc / Drive link, a sent email, a calendar invite,
or a short text result — include one or more artifact blocks in your
final reply. The Doit iOS app renders each block as a compact card under
the task title.

Format (one JSON object per block, wrapped exactly like this):

[[DOIT_ARTIFACT]]
{"key":"<stable id>","type":"link|email|calendar|text|image|options",
 "title":"<short label>","payload":{...}}
[[/DOIT_ARTIFACT]]

Payload shapes by type:
- link:     {"url":"https://...","provider":"googlesheets|googledocs|gmail|..."}
- email:    {"to":["a@b.com"],"subject":"...","body":"...",
             "provider":"gmail",
             "status":"drafted|sent|scheduled",
             "scheduled_at":"<ISO8601 when status=scheduled>"}
- calendar: {"title":"...","start":"<ISO8601>","end":"<ISO8601>",
             "location":"...","attendees":["a@b.com"],"url":"https://..."}
- text:     {"text":"..."}
- image:    {"url":"https://...","provider":"figma|browser|openai|...",
             "prompt":"<optional source prompt>",
             "width":390,"height":844}
- options:  structured comparison / booking list (see below)

Email ``status`` values (required on every email artifact):
- ``drafted`` — not yet sent; awaiting review or approval
- ``sent`` — the send tool succeeded or the user approved Send
- ``scheduled`` — schedule-send was used; include ``scheduled_at`` when known
Reuse the same ``key`` on later turns to update ``status`` in place.

Rules:
- Use a stable ``key`` per artifact and reuse the same key in a later turn
  to update that card rather than creating a new one.
- Multi-step tasks should drill down in the UI: emit the primary deliverable
  first (e.g. key ``sheet`` with type ``link`` and provider ``googlesheets``),
  then emit one ``email`` artifact per draft with distinct keys such as
  ``email-acme``, ``email-beta``, … each with provider ``gmail``. On later
  follow-up turns **for this same todo only**, re-emit earlier artifacts
  from this todo plus any new ones so the header keeps the sheet and
  accumulates draft cards underneath. Never re-emit artifacts discovered
  via session_search or from other todos.
- Do not collapse many drafts into one artifact or one long text block.
- Only emit artifacts for deliverables you created or updated in THIS run
  for this todo's title/detail. Skip intermediate search results, scratch
  notes, tool diagnostics, and pre-existing account resources from unrelated
  prior todos.
- The block must be valid JSON on its own. Do not wrap it in a code fence.
- Anything outside the markers stays in the chat reply as normal prose.
- Use exactly one "Done —" lead-in per final reply. Summarize every
  deliverable in the prose that follows; do not open a second "Done —"
  paragraph for the same turn (artifact links already appear as cards
  under the task title).
- Do not emit artifacts in the same reply as a [[DOIT_INTERACTION]] block;
  re-emit them once the user answers and the task actually finishes.
"""


# Compact cheat-sheet version of the core artifact contract: short rules +
# copy-paste examples. Same contract, fewer tokens, and the examples carry
# the signal weaker models miss in long prose.
_ARTIFACT_CORE_COMPACT = """\

Artifacts (user-visible deliverables) — contract:
End your FINAL reply with one [[DOIT_ARTIFACT]] block per deliverable the
user should see as a card: a created doc/sheet link, a sent email, a
calendar invite, or a short text result. Each block is standalone valid
JSON between the markers, never in a code fence.

Examples (copy these shapes exactly):

[[DOIT_ARTIFACT]]
{"key":"sheet","type":"link","title":"Vendor comparison sheet",
 "payload":{"url":"https://docs.google.com/spreadsheets/d/...","provider":"googlesheets"}}
[[/DOIT_ARTIFACT]]

[[DOIT_ARTIFACT]]
{"key":"email-acme","type":"email","title":"Quote request to Acme",
 "payload":{"to":["ops@acme.com"],"subject":"Quote request",
 "body":"Hi — ...","provider":"gmail","status":"drafted"}}
[[/DOIT_ARTIFACT]]

Payload shapes by type:
- link:     {"url":"https://...","provider":"googlesheets|googledocs|gmail|..."}
- email:    {"to":["a@b.com"],"subject":"...","body":"...","provider":"gmail",
             "status":"drafted|sent|scheduled",
             "scheduled_at":"<ISO8601 when status=scheduled>"}
- calendar: {"title":"...","start":"<ISO8601>","end":"<ISO8601>",
             "location":"...","attendees":["a@b.com"],"url":"https://..."}
- text:     {"text":"..."}
- image:    {"url":"https://...","provider":"figma|browser|openai|...",
             "width":390,"height":844}
- options:  structured comparison/booking list (details appear when relevant)

Email ``status``: ``drafted`` (awaiting review/send), ``sent`` (delivered),
``scheduled`` (schedule-send; include ``scheduled_at`` when known). Re-emit
the same ``key`` with updated ``status`` after send or schedule.

Rules:
- Stable ``key`` per artifact; reuse the SAME key on a later turn to update
  that card instead of creating a new one.
- One card per deliverable: primary link first (e.g. key ``sheet``), then
  one ``email`` artifact per draft with distinct keys (``email-acme``,
  ``email-beta``, …). Never collapse drafts into one long text block.
- On follow-up turns for **this same todo only**, re-emit this todo's
  earlier artifacts plus new ones. Never copy artifacts from session_search
  or other todos.
- Only deliverables you created/updated in THIS run for this todo — no
  scratch notes, search output, tool diagnostics, or unrelated prior work.
- Never emit artifacts in the same reply as a [[DOIT_INTERACTION]] block;
  re-emit them after the user answers.
- Use exactly one "Done —" lead-in per final reply.
"""


_IMAGE_INSTRUCTIONS = """\

Visual deliverables (image):
When the user asks for an image back in Doit — a Figma screen export,
a generated mockup or illustration, a browser screenshot, a chart,
diagram, or any visual asset — emit an ``image`` artifact instead of a
``link`` artifact. The runner downloads the bytes from ``payload.url``
(or reads ``payload.file_path`` when a native tool wrote them locally),
re-hosts the image in Doit's private storage, and the iOS card renders
it inline.

Guidelines for ``image`` artifacts:
- Prefer ``image`` over ``link`` whenever the deliverable is a picture.
  Composio Figma render URLs and most generated-image URLs expire, so a
  raw link card breaks soon after the run finishes; the runner persists
  the image so it stays visible.
- ``payload.url`` must be an http(s) URL the runner can fetch without
  auth. If a tool returns multiple variants, pick the highest-resolution
  PNG/JPG/WebP/SVG.
- Set ``provider`` when known so the card shows the right logo
  (``figma`` for Figma exports, ``browser`` for screenshots, ``openai``
  / model name for generated images).
- Add ``width``/``height`` in pixels and ``prompt`` (the source prompt
  or a short description) when you have them — the iOS card uses both.
- Use distinct ``key`` values when emitting multiple images in one
  reply (``image-home``, ``image-checkout``, …); reuse the same key on
  later turns to update an iteration in place.
- Do not also emit a duplicate ``link`` artifact for the same image —
  one card per asset is enough.
"""


_OPTIONS_INSTRUCTIONS = """\

Comparison / booking options (``options``):
When the user should revisit structured choices — flights, hotels, events,
movie showtimes, haircut slots, rental cars, golf tee times, restaurants,
or similar — emit one ``options`` artifact (not many separate artifacts per
row). Domains differ via ``payload.category`` and per-item ``fields``, not
via new artifact types.

Payload shape:

{"schema":"booking_option","category":"<domain>","provider":"<source>",
 "summary":"<one-line context>","items":[{...}],"selected_id":null}

Each item:

{"id":"<stable id>","title":"<primary label>","subtitle":"<secondary>",
 "badge":"<price or time>","url":"https://...",
 "fields":[{"label":"...","value":"..."}],
 "image_url":null}

Rules:
- Emit **one** ``options`` artifact per comparison set. Use distinct
  ``key`` values when surfacing multiple unrelated sets in one reply
  (``flight-options``, ``hotel-options``).
- Set ``category`` to a short slug: ``flight``, ``hotel``, ``event``,
  ``movie``, ``haircut``, ``golf``, ``rental_car``, ``restaurant``, …
- Use ``fields`` for domain-specific columns (depart/arrive for flights,
  check-in/out for hotels, theater/showtime for movies, stylist/duration
  for haircuts). Do not invent new ``type`` values for each domain.
- After the user picks or you book, re-emit the same artifact with
  ``selected_id`` set to the chosen item's ``id``. Add optional
  ``calendar`` / ``link`` / ``email`` artifacts for confirmations.
- Mid-task comparisons (user must pick now): emit a
  ``[[DOIT_INTERACTION]]`` block with ``kind":"choice"``, the same
  options payload in ``content``, and ``options`` buttons whose ``id``
  matches each ``items[].id``. Do not emit ``options`` artifacts in the
  same reply as ``[[DOIT_INTERACTION]]``; re-emit them once the user
  answers and the task finishes or you save picks for later.

Category examples (fill ``fields`` appropriately):

- flight: summary ``SFO → JFK, Tue Jun 10``; fields Depart / Arrive /
  Airline; badge = price; provider ``google_flights`` when applicable.
- hotel: summary ``San Francisco, 2 nights``; fields Check-in / Check-out /
  Neighborhood; badge = nightly or total price.
- haircut: summary ``Downtown salon, Saturday``; fields Stylist / Duration;
  badge = price or time slot.
- movie: summary ``AMC Metreon, Friday``; fields Theater / Showtime / Rating;
  badge = ticket price; ``image_url`` for poster when available.
"""


_FIGMA_INSTRUCTIONS = """\

Figma workflows:
- Use available Figma Composio tools for connected-account work today:
  discovering accessible Figma resources, reading known file/frame URLs,
  inspecting file JSON/nodes/styles/tokens, rendering nodes, downloading
  images, and comments where supported.
- If official Figma MCP tools such as ``use_figma``, ``upload_assets``,
  ``create_new_file``, ``get_design_context``, ``get_screenshot``, or
  ``search_design_system`` are present in the current tool list, prefer
  them for native canvas edits, design-system search, screenshots, and
  Code Connect-aware work. If they are not present, do not claim you can
  directly write native Figma layers; return the best visual artifact,
  spec, or instructions you can with the available Composio/render tools.
- For ambiguous requests like "the doit Figma file", first check memory
  and session_search for a default Figma team, project, or file URL. If
  missing, ask once for a Figma file/project/team URL and save it to
  memory for future Figma tasks.
- When Figma work changes or proposes a visual result, return both the
  durable ``image`` artifact and a ``link`` artifact to the relevant
  Figma file/frame when you have a URL.
"""


_TTS_INSTRUCTIONS = """\

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

_TTS_OPT_OUT_LINE = """\

Audio: do NOT call the ``text_to_speech`` tool or produce voice memos /
audio artifacts for this task — the user did not ask for spoken audio.
Reply with text only.
"""


def _recall_nudge_enabled() -> bool:
    """Whether the session_search recall nudge is on (DOIT_RECALL_NUDGE).

    Off by default: premium models usually call session_search on their
    own when the user says "like last time". The nudge exists for weaker
    models that skip recall and re-ask or invent placeholders instead.
    """
    return os.getenv("DOIT_RECALL_NUDGE", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


# Phrases that reference earlier work the agent may have done in a prior
# session — the cue that session_search (FTS over prior sessions) would
# recover context the model otherwise re-asks for.
_RECALL_HINT = re.compile(
    r"\b(last\s+time|like\s+(?:before|last)|previous(?:ly)?|"
    r"(?:that|the)\s+(?:draft|doc|document|email|sheet|list|report|summary)\s+"
    r"(?:from|you)|the\s+other\s+day|as\s+(?:before|usual)|"
    r"same\s+as\s+(?:before|last)|you\s+(?:did|made|sent|created|drafted|"
    r"found)\s|do\s+(?:it|that|this)\s+again|once\s+more)\b",
    re.IGNORECASE,
)


def _append_recall_nudge(base: str, *texts: str | None) -> str:
    """One-line session_search nudge when the user references prior work.

    Env-gated and purely additive: when the flag is off or no recall
    phrase matches, the prompt is unchanged.
    """
    if not _recall_nudge_enabled():
        return base
    blob = " ".join(t for t in texts if t)
    if not blob or not _RECALL_HINT.search(blob):
        return base
    return (
        f"{base}\n\n"
        "The user referenced earlier work. Call session_search with the "
        "relevant keywords to recall it before asking the user or redoing "
        "the work."
    )


def concurrent_isolation_nudge() -> str:
    """Append when another task is in flight for the same user."""
    return (
        "\n\nAnother task is running concurrently for this user. Stay strictly "
        "on THIS task's title and detail; do not reuse deliverables or drafts "
        "from other tasks."
    )


def _compact_prompts_enabled() -> bool:
    """Whether the compacted cheat-sheet prose is active.

    Single env flag for instant rollback: setting ``DOIT_COMPACT_PROMPTS=0``
    restores the legacy long-form prose without a deploy. Default on.
    """
    value = os.getenv("DOIT_COMPACT_PROMPTS", "1").strip().lower()
    return value not in {"0", "false", "no", "off"}


# Task-signal detectors for conditional prompt sections. These key on the
# task's own metadata and text (connection_slug, topic, user wording) — never
# on which model is running — so every model gets the same, smaller prompt
# when a section is irrelevant.
_FIGMA_HINT = re.compile(r"\bfigma\b", re.IGNORECASE)

_VISUAL_HINT = re.compile(
    r"\b(image|images|picture|photo|photos|screenshot|screenshots|mockup|"
    r"mock-up|wireframe|illustration|infographic|chart|graph|diagram|logo|"
    r"banner|icon|render|visual|design|draw|sketch)\b",
    re.IGNORECASE,
)

_COMPARISON_HINT = re.compile(
    r"\b(flight|flights|hotel|hotels|book|booking|reserve|reservation|"
    r"restaurant|restaurants|movie|movies|showtime|showtimes|ticket|tickets|"
    r"rental|airbnb|compare|comparison|options|shortlist|short-list|vet|"
    r"tee\s*time|haircut|salon|appointment|itinerary|best|solid|"
    r"vendor|vendors|moving\s+compan)\b",
    re.IGNORECASE,
)

_COMPARISON_TOPICS = frozenset({"travel", "shopping"})


def _append_artifacts_instructions(
    base: str,
    *,
    audio_requested: bool = True,
    connection_slug: str | None = None,
    topic: str | None = None,
    task_text: str = "",
) -> str:
    """Teach the agent the artifact marker contract on every execution turn.

    Kept on the per-todo prompt (not the system prompt that lives in the
    Hermes profile) so the convention is self-contained in this repo and
    easy to evolve without redeploying profiles. Idempotent because the
    runner builds the prompt fresh each turn.

    Domain-specific sections are appended only when task signals suggest
    they are relevant — pure removal of irrelevant context that saves
    tokens for every model:

    - image guidance: visual wording or a Figma task
    - options guidance: comparison/booking wording or travel/shopping topic
    - Figma guidance: Figma connection slug or "figma" in the task text
    - TTS guidance: only when the USER asked for spoken audio; otherwise a
      one-line opt-out (stops unsolicited ElevenLabs voice memos)
    """
    slug = (connection_slug or "").strip().lower()
    text = task_text or ""
    is_figma = slug == "figma" or bool(_FIGMA_HINT.search(text))

    out = base
    out += _ARTIFACT_CORE_COMPACT if _compact_prompts_enabled() else _ARTIFACT_CORE_LEGACY
    if is_figma or _VISUAL_HINT.search(text):
        out += _IMAGE_INSTRUCTIONS
    if (topic or "").strip().lower() in _COMPARISON_TOPICS or _COMPARISON_HINT.search(text):
        out += _OPTIONS_INSTRUCTIONS
    if is_figma:
        out += _FIGMA_INSTRUCTIONS
    out += _TTS_INSTRUCTIONS if audio_requested else _TTS_OPT_OUT_LINE
    return out


_ACTIVITY_INSTRUCTIONS = """\

Public activity updates (for the app's live status UI):
When your visible work changes in a meaningful way, emit a short public
activity line wrapped exactly like this:

[[DOIT_ACTIVITY]]Reading the GitHub repo docs[[/DOIT_ACTIVITY]]

Rules:
- Keep it under 80 characters.
- Make it natural and honest: "Reading project files", "Adding the rule",
  "Preparing the PR summary", "Checking the command result".
- Only describe work you are actually doing or about to do next.
- Do not mention private reasoning, hidden chain-of-thought, raw tool
  arguments, shell commands, file paths, JSON, tokens, or internal errors.
- Do not emit one on every tiny step. Emit when the user-visible phase
  changes: reading, editing, checking, preparing, asking, finishing.
- The activity marker is for live status only. Do not include it inside
  artifact or interaction JSON.
"""


def _append_activity_instructions(base: str) -> str:
    """Teach the agent to emit concise public progress copy for iOS."""
    return base + _ACTIVITY_INSTRUCTIONS


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
  buttons. Wait for the user's response before sending. Do NOT call
  send/email/calendar-create/post tools until after the user taps Send
  on the approval card — the runner blocks unauthorized sends.

- Approval is NOT required for: creating spreadsheets, docs, drafts,
  or other artifacts the user can review at their leisure;
  read-only research, search, or summarisation; sending TTS audio
  back; emitting artifacts. If the user explicitly asked you to
  "review with me" or "ask before <action>", honour that and gate
  even otherwise-safe actions.

- Once approved, perform the action immediately and emit a final
  artifact (or refreshed artifact set) describing what was sent.
  Re-emit each email artifact with the same ``key`` and set
  ``payload.status`` to ``sent`` (or ``scheduled`` with ``scheduled_at``
  when schedule-send was used).

- Never use placeholder emails, names, or body text. Use real data from
  tools/memory or ask the user.
"""


_APPROVAL_INSTRUCTIONS_COMPACT = """\

Approval policy (draft first, ask second):
- Create freely in the user's own workspace — spreadsheets, docs, drafts,
  notes, artifacts. Approval is NOT required for creation, read-only
  research, or summarisation: just do the work and emit the artifact.
- ALWAYS draft before asking. Never stop at "Should I send X?" without
  the actual content — the approval card is meaningless without a draft.
- Approval IS required (after drafting) before: sending an email, sending
  or updating a calendar / meeting invite with attendees other than the
  user, posting publicly, or irreversibly modifying/deleting data. Emit
  one [[DOIT_INTERACTION]] block of kind "approval" with the draft in
  content, then STOP and wait. Do NOT call send/email/calendar-create/post
  tools on this turn — the runner blocks unauthorized sends.

[[DOIT_INTERACTION]]
{"kind":"approval","prompt":"Send this email to Acme?",
 "content":{"to":["ops@acme.com"],"subject":"Quote request","body":"Hi — ..."},
 "options":[{"id":"send","label":"Send","style":"primary"},
            {"id":"edit","label":"Edit","style":"secondary"},
            {"id":"cancel","label":"Cancel","style":"destructive"}],
 "allow_freeform":true}
[[/DOIT_INTERACTION]]

- Once approved, act immediately and emit the final artifact(s).
  Re-emit each email artifact with the same key and set payload.status
  to "sent" (or "scheduled" with scheduled_at when schedule-send was used).
- After the user taps Send on the approval card, you may call send/invite/post
  tools on the resume turn only.
- If the user said "review with me" or "ask before <action>", honour it.
- Never use placeholder emails, names, or body text. Use real data from
  tools/memory or ask the user.
"""


def _append_approval_instructions(base: str) -> str:
    """Append the approval / draft-first policy to every execution prompt.

    Mirrors `_append_artifacts_instructions` so the convention stays
    self-contained in this repo and can evolve without reshipping the
    Hermes profile. The block is idempotent because the runner rebuilds
    the prompt each turn. Compacted variant behind ``DOIT_COMPACT_PROMPTS``.
    """
    if _compact_prompts_enabled():
        return base + _APPROVAL_INSTRUCTIONS_COMPACT
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
    topic: str | None = None,
    processed_attachment_urls: list[str] | None = None,
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
        topic=topic,
    )
    base = _append_task_context_block(base, task_context)

    quoted = [m.strip() for m in messages if m and m.strip()]
    if not quoted:
        if attachment_urls:
            # Image-only follow-up (e.g. a second receipt sent to the same
            # task with no text). Without an explicit "something new
            # arrived" line, weaker models re-do day-1 work or ask what to
            # do; the framing tells them to apply the task's standing
            # instructions to the new image(s) only.
            composed = (
                f"{base}\n\n"
                "The user sent new image attachment(s) with no message. "
                "Apply this task's standing instructions to the newly "
                "attached image(s); do not redo work already completed."
            )
            return _append_attachments(
                composed,
                attachment_urls,
                processed_urls=processed_attachment_urls,
            )
        # Fall back to the base prompt so we never ship an empty follow-up
        # block that would just confuse the model.
        return _append_attachments(
            base, attachment_urls, processed_urls=processed_attachment_urls
        )

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
    composed = _append_recall_nudge(composed, *quoted)
    return _append_attachments(
        composed, attachment_urls, processed_urls=processed_attachment_urls
    )


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

    # Artifacts are the user's durable reality ("the doc", "that sheet") so
    # they keep the largest cap. Messages and raw steps are trimmed harder —
    # a wall of old tool steps dilutes the structured-contract instructions,
    # especially for smaller models on turn 2+.
    if artifacts:
        lines += ["", "Artifacts already created:"]
        for row in artifacts[-20:]:
            lines.append(_format_artifact_context(row))

    if messages:
        lines += ["", "Recent user chat messages:"]
        for row in messages[-10:]:
            body = _truncate_one_line(str(row.get("body") or ""), 500)
            if body:
                lines.append(f"- {body}")

    if steps:
        lines += ["", "Recent agent activity / results:"]
        for row in steps[-15:]:
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
        status = str(payload.get("status") or "drafted").strip()
        scheduled_at = str(payload.get("scheduled_at") or "").strip()
        status_bits = [f"status={status}"]
        if scheduled_at:
            status_bits.append(f"scheduled_at={scheduled_at}")
        details = "; ".join(
            x
            for x in (
                f"to={recipients}" if recipients else "",
                f"subject={subject}" if subject else "",
                ", ".join(status_bits),
                body,
            )
            if x
        )
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


def _append_attachments(
    base: str,
    attachment_urls: list[str] | None,
    *,
    processed_urls: list[str] | None = None,
) -> str:
    """Append a stable ``Attachments (images):`` block at the end of a prompt.

    The block is only emitted when there is at least one URL. The agent's
    system prompt explains that this block is the canonical place to find
    images for the current task, and that it should call ``vision_analyze``
    on these URLs when the task requires looking at them.

    On follow-up turns the runner also passes ``processed_urls`` — images
    attached before the last completed run. Signed URLs are regenerated
    every run, so without these labels the model cannot tell yesterday's
    receipt from today's and may re-process the old one. First runs pass no
    processed URLs and keep today's flat format byte-identical.
    """
    cleaned = [u.strip() for u in (attachment_urls or []) if u and u.strip()]
    cleaned_processed = [
        u.strip() for u in (processed_urls or []) if u and u.strip()
    ]
    if not cleaned and not cleaned_processed:
        return base
    block = ["", "", "Attachments (images):"]
    if cleaned_processed:
        block.append("Previously processed (do not re-process unless asked):")
        block += [f"- {url}" for url in cleaned_processed]
        if cleaned:
            block.append("Newly attached since the last run:")
            block += [f"- {url}" for url in cleaned]
    else:
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
