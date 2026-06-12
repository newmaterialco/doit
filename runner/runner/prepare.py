"""Preparation phase: rewrite + classify + clarify a todo before execution.

Each new todo enters ``status='preparing'`` so the runner can do a single
lightweight Hermes pass that:

    * rewrites the user's raw input into a concise title,
    * picks the most likely Composio toolkit slug (for the icon on the card),
    * decides whether one clarifying question is needed before any action,

and then either flips the todo to ``status='requested'`` so the execution
loop picks it up automatically, or to ``status='needs_input'`` with a
``todo_interactions`` row carrying ``payload.phase='prepare'``.

This module is intentionally pure: the I/O lives in ``runner.runner``. We
keep the JSON contract, prompt, and parser here so they can be unit-tested
without Supabase or Hermes.
"""
from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass, field, replace
from typing import Any

log = logging.getLogger(__name__)


# Marker the model uses to wrap its preparation JSON. Distinct from the
# execution-time [[DOIT_INTERACTION]] marker so an accidental prep reply
# inside an execution run isn't misinterpreted, and vice versa.
PREP_OPEN = "[[DOIT_PREP]]"
PREP_CLOSE = "[[/DOIT_PREP]]"

_PREP_RE = re.compile(
    re.escape(PREP_OPEN) + r"\s*(\{.*?\})\s*" + re.escape(PREP_CLOSE),
    re.DOTALL,
)


# Toolkit slugs the iOS app has asset images for. Keep in sync with
# ``supabase/functions/integrations/index.ts`` CATALOG and the asset
# catalog under ``ios/doit/doit/Assets.xcassets``.
CONNECTION_SLUGS: frozenset[str] = frozenset(
    {
        "gmail",
        "googlecalendar",
        "googledrive",
        "googledocs",
        "googlesheets",
        "slack",
        "notion",
        "linear",
        "github",
        "reddit",
        "hunter",
        "linkedin",
        "figma",
    }
)

TODO_TOPICS: frozenset[str] = frozenset(
    {
        "communication",
        "scheduling",
        "research",
        "documents",
        "coding",
        "finance",
        "shopping",
        "travel",
        "personal",
        "work",
        "other",
    }
)


PREP_INSTRUCTIONS = (
    "You are the PREPARATION pass for a personal assistant. You will NOT "
    "execute the user's task and you will NOT call any tools. Your single "
    "job is to read the user's new todo and emit one structured JSON block "
    "describing how the agent should approach it.\n\n"
    "Output exactly one JSON object wrapped between these markers, with no "
    "surrounding prose:\n"
    f"{PREP_OPEN}\n"
    "{\n"
    "  \"title\": \"Clear, concise rewording of the task (<= 110 chars). "
    "Preserve the user's intent AND important specifics.\",\n"
    "  \"connection_slug\": \"<one of the allowed slugs from the prompt, "
    "or null if no external connection is needed / you cannot pick one>\",\n"
    "  \"topic\": \"communication\" | \"scheduling\" | \"research\" | "
    "\"documents\" | \"coding\" | \"finance\" | \"shopping\" | \"travel\" | "
    "\"personal\" | \"work\" | \"other\",\n"
    "  \"collection_name\": \"Short durable project/company/client/event name, "
    "or null when there is no named collection\",\n"
    "  \"summary\": \"One short sentence describing the planned action.\",\n"
    "  \"kind\": \"task\" | \"cron\",\n"
    "  \"schedule\": \"Required when kind=cron. Hermes-style schedule string "
    "(e.g. '0 9 * * *', 'every 2h', '30m').\",\n"
    "  \"schedule_display\": \"Human-readable schedule for the UI when kind=cron "
    "(e.g. 'Every day at 9:00 AM').\",\n"
    "  \"tasks\": [\n"
    "    {\"title\": \"...\", \"connection_slug\": null, \"topic\": \"work\", "
    "\"collection_name\": null, \"summary\": \"...\"}\n"
    "  ],\n"
    "  \"ready\": true | false,\n"
    "  \"clarification\": {\n"
    "    \"prompt\": \"The single question to ask the user (required if "
    "ready=false).\",\n"
    "    \"options\": [\n"
    "      {\"id\": \"short_id\", \"label\": \"Button label\", "
    "\"style\": \"primary\" | \"secondary\" | \"destructive\"}\n"
    "    ],\n"
    "    \"allow_freeform\": true,\n"
    "    \"freeform_placeholder\": \"Optional hint text\"\n"
    "  }\n"
    "}\n"
    f"{PREP_CLOSE}\n\n"
    "Rules:\n"
    "- Only ask one clarifying question, and only when the missing info is "
    "required before the agent could safely act. Vague-but-defaultable "
    "tasks should set ready=true.\n"
    "- Prefer ready=true. Confirmation of irreversible actions (sending an "
    "email, deleting, posting) happens later in the execution phase, not "
    "here.\n"
    "- The title is for the user's card, not just a category label. Keep "
    "specifics that make the task recognizable: recipients/emails, people, "
    "companies, dates/times, locations, document names, event names, and "
    "short key instructions. Example: 'Send a test email to gabe@test.com' "
    "should stay essentially that, not become 'Send a test email'.\n"
    "- Remove filler, hedging, and rambling, but do not drop the object or "
    "target of the action just to make the title shorter.\n"
    "- Pick connection_slug only from the list of allowed slugs supplied "
    "in the prompt. If unsure, use null.\n"
    "- Pick topic only from the allowed topic values supplied in the prompt. "
    "Use other if none of the values fit.\n"
    "- Prefer consistency with the user's existing organization examples in "
    "the prompt. If a new todo is similar to an existing example, reuse the "
    "same topic and collection_name unless the new request clearly belongs "
    "somewhere else.\n"
    "- Invoice, billing, receipt, reimbursement, payment, tax, and accounting "
    "tasks should generally use topic=\"finance\". Use topic=\"documents\" "
    "only when the task is primarily drafting, editing, organizing, or "
    "retrieving a document and not about money/accounting.\n"
    "- Set collection_name only for a durable named thing the user is likely "
    "to return to: a project, company, client, event, household initiative, "
    "or named area of responsibility. Do NOT create collections for generic "
    "task types like emails, research, calendar, shopping, or documents. "
    "Normalize obvious repeats into one short display name when possible.\n"
    "- Set kind=\"cron\" when the user wants a RECURRING automation on a "
    "schedule (daily email check, hourly monitoring, weekly reports). "
    "One-off tasks are kind=\"task\" (default). Cron jobs must include "
    "schedule and schedule_display; set ready=true unless the recurrence "
    "pattern itself is ambiguous.\n"
    "- CRITICAL kind decision table (follow exactly):\n"
    "  * \"Every morning at 9am check email and create tasks\" → "
    "kind=cron, schedule=\"0 9 * * *\", schedule_display=\"Every day at 9:00 AM\"\n"
    "  * \"Check my inbox every 2 hours\" → kind=cron, schedule=\"every 2h\", "
    "schedule_display=\"Every 2 hours\"\n"
    "  * \"Check the news site every Tuesday\" → kind=cron, "
    "schedule=\"0 9 * * 2\", schedule_display=\"Every Tuesday at 9:00 AM\"\n"
    "  * \"Remind me tomorrow at 3pm to call mom\" → kind=task (a one-off "
    "reminder, even though it has a time)\n"
    "  * \"Check X website on Tuesday and tell me what it says\" → kind=task "
    "(a single dated task, not a recurrence)\n"
    "  * \"Send an email to John\" → kind=task (no schedule fields)\n"
    "  * \"Create a Google Doc where I'll send bugs every now and then\" → "
    "kind=task (future use is not a schedule; never invent one)\n"
    "  kind=cron ONLY when the user asks Doit to RUN something on a cadence "
    "(daily/hourly/weekly/every <unit>/each <unit>/recurring). A one-off "
    "date or time, or vague future use (\"every now and then\", "
    "\"occasionally\", \"whenever\"), is kind=task. Never invent a default "
    "schedule the user did not ask for.\n"
    "- Wall-clock cron times (e.g. \"0 9 * * *\") are evaluated in the "
    "user's local timezone — the runner pins each new cron job to the "
    "timezone the user is in when they create it. Treat \"9am\" as 9am "
    "local; do NOT convert to UTC.\n"
    "- Use \"tasks\" ONLY when the user's single input clearly contains "
    "multiple independent todos that should each get their own card. "
    "The first task stays on the original row; extras become separate "
    "prepared todos that wait for the user to tap Do it. Omit \"tasks\" "
    "or use a one-element array for a single task. Do not split a single "
    "coherent action.\n"
    "- NEVER split one coordinated workflow into multiple tasks. If the "
    "user asks for a spreadsheet AND emails, research AND a summary, or "
    "create X and then do Y in one request, that is ONE task — the agent "
    "delivers multiple artifacts in one run. Examples that must stay ONE "
    "task (no tasks[] split):\n"
    "  * \"Create a Google Sheet of 4 moving companies and draft outreach "
    "emails\" → single task\n"
    "  * \"Research competitors and put them in a doc\" → single task\n"
    "  * \"Find flights and email the options to my partner\" → single task\n"
    "Only split when the user clearly listed unrelated items that could "
    "each be done on their own (e.g. \"buy milk and schedule a dentist "
    "appointment\").\n"
    "- Do NOT call tools. Do NOT write anything outside the JSON block.\n"
)


@dataclass
class PrepTask:
    """One task in a multi-task split."""

    title: str
    connection_slug: str | None = None
    topic: str | None = None
    collection_name: str | None = None
    summary: str | None = None


@dataclass
class PrepResult:
    """Parsed output of the preparation phase."""

    ready: bool
    kind: str = "task"
    title: str | None = None
    connection_slug: str | None = None
    topic: str | None = None
    collection_name: str | None = None
    summary: str | None = None
    schedule: str | None = None
    schedule_display: str | None = None
    additional_tasks: list[PrepTask] = field(default_factory=list)
    clarification_prompt: str | None = None
    clarification_options: list[dict[str, Any]] = field(default_factory=list)
    clarification_allow_freeform: bool = True
    clarification_placeholder: str | None = None

    @property
    def is_cron(self) -> bool:
        return self.kind == "cron"

    @property
    def needs_clarification(self) -> bool:
        return not self.ready and bool(self.clarification_prompt)


def parse_prepare(
    text: str,
    allowed_slugs: frozenset[str] | set[str] = CONNECTION_SLUGS,
) -> PrepResult | None:
    """Extract a :class:`PrepResult` from the model's reply, or ``None``.

    Returns ``None`` if no JSON block is present or the JSON is malformed —
    the caller should fall back to letting the user proceed with the raw
    title so a broken preparation pass never blocks the user.
    """
    if not text:
        return None
    match = _PREP_RE.search(text)
    if not match:
        return None
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError as e:
        log.warning("prep JSON parse failed: %s", e)
        return None
    if not isinstance(data, dict):
        return None

    title = _clean_str(data.get("title"), max_len=200)
    summary = _clean_str(data.get("summary"), max_len=400)
    slug = _clean_str(data.get("connection_slug"), max_len=64)
    if slug:
        slug_lc = slug.lower()
        slug = slug_lc if slug_lc in allowed_slugs else None
    topic = _clean_str(data.get("topic"), max_len=32)
    if topic:
        topic_lc = topic.lower()
        topic = topic_lc if topic_lc in TODO_TOPICS else "other"
    collection_name = _clean_collection_name(data.get("collection_name"))

    ready_raw = data.get("ready")
    ready = True if ready_raw is None else bool(ready_raw)

    kind_raw = _clean_str(data.get("kind"), max_len=16)
    kind = "cron" if kind_raw == "cron" else "task"

    schedule = _clean_str(data.get("schedule"), max_len=120)
    schedule_display = _clean_str(data.get("schedule_display"), max_len=200)

    parsed_tasks: list[PrepTask] = []
    raw_tasks = data.get("tasks")
    if isinstance(raw_tasks, list):
        for item in raw_tasks:
            if not isinstance(item, dict):
                continue
            t_title = _clean_str(item.get("title"), max_len=200)
            if not t_title:
                continue
            t_slug = _clean_str(item.get("connection_slug"), max_len=64)
            if t_slug:
                t_slug = t_slug.lower() if t_slug.lower() in allowed_slugs else None
            t_topic = _clean_str(item.get("topic"), max_len=32)
            if t_topic:
                t_topic_lc = t_topic.lower()
                t_topic = t_topic_lc if t_topic_lc in TODO_TOPICS else "other"
            t_collection_name = _clean_collection_name(item.get("collection_name"))
            t_summary = _clean_str(item.get("summary"), max_len=400)
            parsed_tasks.append(
                PrepTask(
                    title=t_title,
                    connection_slug=t_slug,
                    topic=t_topic,
                    collection_name=t_collection_name,
                    summary=t_summary,
                )
            )
    # The prep contract says `tasks[0]` is represented by the original todo
    # row; only tasks after the first should become new rows. This also
    # handles models that emit a one-item `tasks` array for a single task.
    if parsed_tasks and not title:
        title = parsed_tasks[0].title
    additional_tasks = parsed_tasks[1:] if parsed_tasks else []

    clarification = data.get("clarification")
    c_prompt: str | None = None
    c_options: list[dict[str, Any]] = []
    c_allow_freeform = True
    c_placeholder: str | None = None
    if isinstance(clarification, dict):
        c_prompt = _clean_str(clarification.get("prompt"), max_len=500)
        raw_opts = clarification.get("options")
        if isinstance(raw_opts, list):
            for opt in raw_opts:
                cleaned = _clean_option(opt)
                if cleaned:
                    c_options.append(cleaned)
        if "allow_freeform" in clarification:
            c_allow_freeform = bool(clarification["allow_freeform"])
        c_placeholder = _clean_str(
            clarification.get("freeform_placeholder"),
            max_len=120,
        )

    if not ready and not c_prompt:
        # Model said "not ready" without a question; treat as ready so the
        # user isn't stuck waiting for input that will never arrive.
        ready = True

    return PrepResult(
        ready=ready,
        kind=kind,
        title=title,
        connection_slug=slug,
        topic=topic,
        collection_name=collection_name,
        summary=summary,
        schedule=schedule,
        schedule_display=schedule_display,
        additional_tasks=additional_tasks,
        clarification_prompt=c_prompt,
        clarification_options=c_options,
        clarification_allow_freeform=c_allow_freeform,
        clarification_placeholder=c_placeholder,
    )


def build_prepare_prompt(
    *,
    title: str,
    detail: str,
    allowed_slugs: frozenset[str] | set[str] = CONNECTION_SLUGS,
    prior: dict[str, Any] | None = None,
    attachment_urls: list[str] | None = None,
    organization_examples: list[dict[str, Any]] | None = None,
    attachment_count: int = 0,
) -> str:
    """Build the per-todo input the runner sends to Hermes for preparation.

    ``prior`` is the previously-responded prep interaction, if the user
    answered a clarifying question and we are re-running preparation. It
    must look like a row from ``todo_interactions``: at least ``prompt``,
    ``payload``, and ``response``.

    ``attachment_urls`` are short-lived signed URLs to user-attached images.
    The preparation pass usually shouldn't call ``vision_analyze`` itself —
    that is the execution phase's job — but knowing that images are
    attached helps it pick the right ``connection_slug`` and write a
    sharper title.
    """
    task = f"{title}\n\n{detail}".strip() if detail else title
    slugs = ", ".join(sorted(allowed_slugs))
    topics = ", ".join(sorted(TODO_TOPICS))
    lines = [
        "New todo to prepare (do NOT execute it):",
        task,
        "",
        f"Allowed connection_slug values: [{slugs}] or null.",
        f"Allowed topic values: [{topics}].",
        "Optional collection_name should be a short durable project, company, client, event, or named responsibility; use null for generic tasks.",
        "Consistency rules:",
        "- Before choosing topic or collection_name, compare this todo to the existing organization examples below and reuse matching organization when appropriate.",
        "- Invoice, billing, receipt, reimbursement, payment, tax, and accounting tasks should generally use topic=\"finance\". Use topic=\"documents\" only when the task is just drafting, editing, organizing, or retrieving a document.",
    ]
    if organization_examples:
        lines += ["", "Existing organization examples for this user:"]
        # Cap at 8: prep is a classification pass, not a recall task — a
        # few examples anchor topic/collection style without the token tax.
        for example in organization_examples[:8]:
            title_text = _clean_str(example.get("title"), max_len=90)
            topic = _clean_str(example.get("topic"), max_len=32)
            collection_name = _clean_collection_name(example.get("collection_name"))
            if not title_text or not (topic or collection_name):
                continue
            org_parts = []
            if topic:
                org_parts.append(f"topic={topic}")
            if collection_name:
                org_parts.append(f"collection_name={collection_name}")
            lines.append(f"- {title_text} ({', '.join(org_parts)})")
    if prior:
        prior_prompt = (prior.get("prompt") or "").strip()
        response = prior.get("response") or {}
        option_id = str(response.get("option_id") or "").strip()
        freeform = str(response.get("text") or "").strip()
        lines += ["", "You previously asked the user:", f'  "{prior_prompt}"']
        if option_id:
            lines.append(f"They picked option: {option_id}")
        if freeform:
            lines.append(f"They also wrote: {freeform}")
        lines.append("")
        lines.append(
            "Incorporate their answer and finalize the preparation. Set "
            "ready=true unless something materially new is still missing. "
            "Do not ask the same question again."
        )
    if attachment_count and not attachment_urls:
        # Signing URLs costs a round-trip per attachment and prep should
        # not analyze images anyway — the count is enough to pick a slug
        # and write a sharper title. Execution gets the real signed URLs.
        lines += [
            "",
            f"The user attached {attachment_count} image(s). Signed URLs "
            "will be provided at execution time; factor the attachment "
            "into the title and connection_slug but do not analyze it now.",
        ]
    base = "\n".join(lines)

    # Reuse the same Attachments block format as the execution prompt so the
    # agent recognizes it across phases.
    from .prompt import _append_attachments

    return _append_attachments(base, attachment_urls)


# Phrases that read like "every ..." but describe irregular, user-driven
# future use — never a schedule Doit should run on. Stripped from the text
# before recurrence detection so e.g. "send bugs every now and then" cannot
# promote a one-off setup task to cron.
_ONE_OFF_PHRASES = re.compile(
    r"\b("
    r"every\s+now\s+and\s+then|every\s+once\s+in\s+a\s+while|"
    r"now\s+and\s+then|once\s+in\s+a\s+while|from\s+time\s+to\s+time|"
    r"occasionally|sporadically|whenever|every\s+time\b"
    r")",
    re.IGNORECASE,
)

# An explicit recurrence directive: the user asked for something to happen on
# a cadence. "every"/"each" must be anchored to a schedulable unit so that
# bare clock times ("remind me tomorrow at 3pm") and irregular phrases
# ("every now and then") never count as recurring. Shared by the promote
# (augment_cron_from_text) and demote (demote_unrequested_cron) safety nets
# so they can never disagree.
_RECURRENCE_DIRECTIVE = re.compile(
    r"\b(?:"
    r"daily|hourly|weekly|monthly|nightly|recurring|"
    r"(?:every|each)\s+(?:other\s+)?(?:\d+\s*)?"
    r"(?:m|min|mins|minute|minutes|h|hr|hrs|hour|hours|"
    r"d|day|days|week|weeks|month|months|"
    r"morning|mornings|evening|evenings|night|nights|"
    r"afternoon|afternoons|weekday|weekdays|weekend|weekends|"
    r"monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
    r"mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)"
    r")\b",
    re.IGNORECASE,
)

_EVERY_N_UNIT = re.compile(
    r"every\s+(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|"
    r"d|day|days)\b",
    re.IGNORECASE,
)

_AT_TIME = re.compile(
    r"(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b",
    re.IGNORECASE,
)

_WEEKDAY_DIRECTIVE = re.compile(
    r"(?:every|each)\s+(?:other\s+)?"
    r"(monday|tuesday|wednesday|thursday|friday|saturday|sunday)",
    re.IGNORECASE,
)

# Cron day-of-week numbers (0=Sunday).
_WEEKDAY_DOW = {
    "sunday": 0,
    "monday": 1,
    "tuesday": 2,
    "wednesday": 3,
    "thursday": 4,
    "friday": 5,
    "saturday": 6,
}


def has_recurrence_directive(raw_text: str) -> bool:
    """True when the user explicitly asked for a recurring cadence.

    This is the single source of truth for both safety nets: promotion
    (model said task, text says recurring) and demotion (model said cron,
    text never asked for one). Irregular "future use" phrasing like
    "every now and then" is excluded.
    """
    text = (raw_text or "").strip()
    if not text:
        return False
    cleaned = _ONE_OFF_PHRASES.sub(" ", text)
    return bool(_RECURRENCE_DIRECTIVE.search(cleaned))


def infer_recurring_schedule(raw_text: str) -> tuple[str, str] | None:
    """Best-effort schedule inference from the user's raw input.

    Returns ``(schedule, schedule_display)`` or ``None`` if the text does not
    contain an explicit recurrence directive. Used when the prep model
    returns kind=task for an input that clearly asks for automation.

    One-off inputs with bare clock times ("remind me tomorrow at 3pm") and
    irregular future-use phrasing ("send bugs every now and then") must
    return ``None`` — those are normal tasks, not cron jobs.
    """
    text = (raw_text or "").strip()
    if not text or not has_recurrence_directive(text):
        return None
    lower = _ONE_OFF_PHRASES.sub(" ", text.lower())

    m = _EVERY_N_UNIT.search(lower)
    if m:
        n = int(m.group(1))
        unit = m.group(2).lower()
        if unit.startswith("m"):
            return (f"every {n}m", f"Every {n} minutes")
        if unit.startswith("h"):
            return (f"every {n}h", f"Every {n} hours")
        if unit.startswith("d"):
            return (f"every {n}d", f"Every {n} days")

    if re.search(r"\b(hourly|every hour)\b", lower):
        return ("every 1h", "Every hour")

    if re.search(r"\bweekly|every week\b", lower):
        return ("0 9 * * 1", "Every week on Monday at 9:00 AM")

    wd = _WEEKDAY_DIRECTIVE.search(lower)
    if wd:
        day = wd.group(1).lower()
        dow = _WEEKDAY_DOW[day]
        tm = _AT_TIME.search(lower[wd.end():])
        if tm:
            hour, minute, meridiem = _parse_clock(tm)
            return (
                f"{minute} {hour} * * {dow}",
                f"Every {day.capitalize()} at {_format_clock(hour, minute, meridiem)}",
            )
        return (f"0 9 * * {dow}", f"Every {day.capitalize()} at 9:00 AM")

    if "every morning" in lower or "each morning" in lower:
        return ("0 9 * * *", "Every day at 9:00 AM")

    if "every evening" in lower or "each evening" in lower:
        return ("0 18 * * *", "Every day at 6:00 PM")

    if re.search(r"\b(daily|every day)\b", lower):
        tm = _AT_TIME.search(lower)
        if tm:
            hour, minute, meridiem = _parse_clock(tm)
            return (
                f"{minute} {hour} * * *",
                f"Every day at {_format_clock(hour, minute, meridiem)}",
            )
        return ("0 9 * * *", "Every day at 9:00 AM")

    tm = _AT_TIME.search(lower)
    if tm and re.search(r"\bevery\b", lower):
        hour, minute, meridiem = _parse_clock(tm)
        return (
            f"{minute} {hour} * * *",
            f"Every day at {_format_clock(hour, minute, meridiem)}",
        )

    # Explicit recurrence directive without a parseable time — default to
    # daily 9am. We already know the directive is present (checked above).
    return ("0 9 * * *", "Every day at 9:00 AM")


def augment_cron_from_text(result: PrepResult, raw_text: str) -> PrepResult:
    """Promote to cron when user text is recurring but the model missed it."""
    inferred = infer_recurring_schedule(raw_text)
    if inferred is None:
        return result

    schedule, display = inferred

    if result.is_cron and result.schedule:
        return result

    log.info(
        "prep cron heuristic: promoting kind=%s schedule=%r from text=%r",
        result.kind,
        schedule,
        raw_text[:120],
    )

    updates: dict[str, Any] = {
        "kind": "cron",
        "schedule": result.schedule or schedule,
        "schedule_display": result.schedule_display or display,
        "ready": True,
    }
    return replace(result, **updates)


def demote_unrequested_cron(result: PrepResult, raw_text: str) -> PrepResult:
    """Demote model-hallucinated cron jobs back to one-off tasks.

    Smaller models sometimes invent a schedule ("Daily at 9:00 AM") for
    inputs that only describe future use, e.g. "create a doc where I'll
    send bugs every now and then". If the model returned kind=cron but the
    raw user text contains no explicit recurrence directive, this guard
    demotes the result to a normal task and clears the schedule fields.

    Uses the same recurrence detector as ``augment_cron_from_text`` so the
    promote and demote safety nets can never disagree.
    """
    if not result.is_cron:
        return result
    if has_recurrence_directive(raw_text):
        return result

    log.info(
        "prep cron guard: demoting unrequested cron schedule=%r from text=%r",
        result.schedule,
        (raw_text or "")[:120],
    )
    return replace(
        result,
        kind="task",
        schedule=None,
        schedule_display=None,
    )


# ---------------------------------------------------------------------------
# Deterministic prep fast-path (DOIT_PREP_FAST_PATH)
# ---------------------------------------------------------------------------


def prep_fast_path_enabled() -> bool:
    """Whether the deterministic prep bypass is on (off by default).

    The LLM prep pass stays the common path — it makes decisions (one-off
    vs recurring gray zones, title rewrite, connection slug) that regex
    can't. The fast path only skips Hermes for the narrow obvious cases.
    """
    return os.getenv("DOIT_PREP_FAST_PATH", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


@dataclass
class FastPathDecision:
    """Verdict from the deterministic prep classifier.

    ``kind="task"`` → queue as-is (trivial bare reminder); ``kind="cron"``
    → insert a cron job directly with the inferred schedule.
    """

    kind: str
    schedule: str | None = None
    schedule_display: str | None = None


# Anything that smells like tool work, an external site, or a connected
# service must go through LLM prep so it gets a connection_slug, a title
# rewrite, and the one-off vs recurring judgment call.
_FAST_PATH_TOOL_HINT = re.compile(
    r"\b(email|e-?mail|gmail|inbox|send|reply|forward|draft|check|search|"
    r"find|look\s*up|book|buy|purchase|order|schedule|calendar|invite|"
    r"meeting|browse|website|site|web|post|tweet|message|slack|notion|"
    r"sheet|doc|docs|figma|github|linear|reddit|linkedin|summarize|"
    r"research|compare|track|monitor|scan|review|analyze|update|create|"
    r"build|make|write|fetch|download|upload|list)\b",
    re.IGNORECASE,
)

_FAST_PATH_URL = re.compile(
    r"(https?://|www\.|\.com\b|\.org\b|\.net\b|\.io\b|\.dev\b|\.app\b)",
    re.IGNORECASE,
)

# "on Tuesday" style date-qualified tasks are exactly the one-off vs
# recurring gray zone the LLM should judge — never fast-path them.
_FAST_PATH_DATE_QUALIFIER = re.compile(
    r"\bon\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
    r"mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|the\s+\d{1,2}(?:st|nd|rd|th)?)\b",
    re.IGNORECASE,
)

# Cadences specific enough to convert deterministically. The generic
# inferencer falls back to "daily 9am" for any directive it can't parse
# ("every other weekend") — that fallback is fine as a safety net for the
# LLM path but not confident enough to skip the LLM entirely.
_FAST_PATH_CONFIDENT_CADENCE = re.compile(
    r"\b(daily|hourly|weekly|nightly|"
    r"every\s+(?:day|hour|week|morning|evening|night|weekday)|"
    r"each\s+(?:day|morning|evening|night)|"
    r"(?:every|each)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|"
    r"every\s+\d+\s*(?:m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days))\b",
    re.IGNORECASE,
)

_BARE_REMINDER = re.compile(r"^\s*remind\s+me\b", re.IGNORECASE)

_EXPLICIT_TIME = re.compile(
    r"\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|\b\d{1,2}:\d{2}\b|"
    r"\b(tomorrow|tonight|today|noon|midnight)\b",
    re.IGNORECASE,
)


# ---------------------------------------------------------------------------
# Complexity signals (Phase 2e): tasks that must keep the full agent lane.
# Research+creation, multiple outputs, external actions, and comparison
# workflows must never be fast-pathed or simplified deterministically —
# they need artifacts, approvals, and progress handling.
# ---------------------------------------------------------------------------

_COMPLEX_RESEARCH_CREATE = re.compile(
    r"\b(?:find|research|look\s*up|search)\b.*\b(?:and|then)\b.*"
    r"\b(?:build|create|draft|make|write|put\s+together)\b",
    re.IGNORECASE | re.DOTALL,
)

_COMPLEX_EXTERNAL_ACTION = re.compile(
    r"\b(send|book|purchase|buy|reserve|post|invite|outreach)\b",
    re.IGNORECASE,
)

_COMPLEX_WORKFLOW = re.compile(
    r"\b(travel|trip|flight|flights|hotel|hotels|moving|move\s+(?:from|to)|"
    r"relocat\w*|shopping|vendor|vendors|itinerary)\b",
    re.IGNORECASE,
)

_COMPLEX_COMPARISON = re.compile(
    r"\b(options?|compare|comparison|vet|vetted|best|solid|shortlist|"
    r"short-list)\b",
    re.IGNORECASE,
)

_COMPLEX_MULTI_OUTPUT = re.compile(
    r"(?:\b(?:spreadsheet|sheet|doc|document)\b.*\b(?:email|invite|calendar)\b)|"
    r"(?:\b(?:email|invite|calendar)\b.*\b(?:spreadsheet|sheet|doc|document)\b)",
    re.IGNORECASE | re.DOTALL,
)


def is_complex_task(raw_text: str) -> bool:
    """True when the input matches any full-agent-lane complexity signal."""
    text = (raw_text or "").strip()
    if not text:
        return False
    return any(
        pattern.search(text)
        for pattern in (
            _COMPLEX_RESEARCH_CREATE,
            _COMPLEX_EXTERNAL_ACTION,
            _COMPLEX_WORKFLOW,
            _COMPLEX_COMPARISON,
            _COMPLEX_MULTI_OUTPUT,
        )
    )


# The three prep lanes. One shared classifier, single decision point — the
# trivial-reminder bypass and the complexity signals must never be two
# parallel heuristics that drift apart.
PREP_LANE_TRIVIAL = "trivial_reminder"
PREP_LANE_CRON = "obvious_cron"
PREP_LANE_FULL = "full_agent"


@dataclass
class PrepLane:
    """Output of ``classify_prep_lane``: lane plus cron payload if any."""

    lane: str
    schedule: str | None = None
    schedule_display: str | None = None


def classify_prep_lane(raw_text: str) -> PrepLane:
    """Single deterministic decision point for the prep pipeline.

    Three outputs:

    - ``trivial_reminder`` → skip LLM prep, queue immediately (narrow:
      bare reminders with an explicit time only).
    - ``obvious_cron`` → deterministic cron insert (explicit recurrence
      directive + confidently parseable cadence only).
    - ``full_agent`` → LLM prep + full agent lane. This is the default
      and the common path — it covers normal requests ("Check X website
      on Tuesday") as well as complex multi-step work (research, booking,
      outreach), which must never be fast-pathed or simplified.
    """
    text = (raw_text or "").strip()
    if not text or len(text) > 200:
        return PrepLane(PREP_LANE_FULL)
    # Complexity guard first: research/booking/outreach workflows keep the
    # full lane no matter what other patterns match.
    if is_complex_task(text):
        return PrepLane(PREP_LANE_FULL)
    if _FAST_PATH_URL.search(text):
        return PrepLane(PREP_LANE_FULL)
    if _FAST_PATH_DATE_QUALIFIER.search(text):
        return PrepLane(PREP_LANE_FULL)

    if has_recurrence_directive(text):
        # Confident recurring: explicit directive AND a specifically
        # parseable cadence. Anything fuzzier ("every other weekend") is
        # ambiguous — let the LLM sort it out.
        if not _FAST_PATH_CONFIDENT_CADENCE.search(text):
            return PrepLane(PREP_LANE_FULL)
        inferred = infer_recurring_schedule(text)
        if inferred is None:
            return PrepLane(PREP_LANE_FULL)
        schedule, display = inferred
        return PrepLane(
            PREP_LANE_CRON, schedule=schedule, schedule_display=display
        )

    if not _BARE_REMINDER.match(text):
        return PrepLane(PREP_LANE_FULL)
    if _FAST_PATH_TOOL_HINT.search(text):
        return PrepLane(PREP_LANE_FULL)
    if not _EXPLICIT_TIME.search(text):
        return PrepLane(PREP_LANE_FULL)
    return PrepLane(PREP_LANE_TRIVIAL)


def prep_fast_path(raw_text: str) -> FastPathDecision | None:
    """Conservative deterministic classifier for skipping LLM prep.

    Thin adapter over ``classify_prep_lane``; ``None`` means "go through
    normal LLM prep with the full agent lane" and must stay the
    overwhelmingly common answer.
    """
    lane = classify_prep_lane(raw_text)
    if lane.lane == PREP_LANE_TRIVIAL:
        return FastPathDecision(kind="task")
    if lane.lane == PREP_LANE_CRON and lane.schedule:
        return FastPathDecision(
            kind="cron",
            schedule=lane.schedule,
            schedule_display=lane.schedule_display,
        )
    return None


def _parse_clock(match: re.Match[str]) -> tuple[int, int, str | None]:
    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    meridiem = (match.group(3) or "").lower() or None
    if meridiem == "pm" and hour < 12:
        hour += 12
    if meridiem == "am" and hour == 12:
        hour = 0
    return hour, minute, meridiem


def _format_clock(hour: int, minute: int, meridiem: str | None) -> str:
    if meridiem:
        display_hour = int(hour)
        if display_hour == 0:
            display_hour = 12
        elif display_hour > 12:
            display_hour -= 12
        return f"{display_hour}:{minute:02d} {meridiem.upper()}"
    return f"{hour:02d}:{minute:02d}"


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


def _clean_str(value: Any, *, max_len: int) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    return text[:max_len]


def _clean_collection_name(value: Any) -> str | None:
    text = _clean_str(value, max_len=80)
    if text is None:
        return None
    generic = {
        "calendar",
        "coding",
        "communication",
        "documents",
        "emails",
        "finance",
        "other",
        "research",
        "scheduling",
        "shopping",
        "travel",
        "work",
    }
    if text.lower() in generic:
        return None
    return re.sub(r"\s+", " ", text)


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
