"""Preparation phase: rewrite + classify + clarify a todo before execution.

Each new todo enters ``status='preparing'`` so the runner can do a single
lightweight Hermes pass that:

    * rewrites the user's raw input into a concise title,
    * picks the most likely Composio toolkit slug (for the icon on the card),
    * decides whether one clarifying question is needed before any action,

and then either flips the todo to ``status='todo'`` (ready for the user to
tap "Do it") or to ``status='needs_input'`` with a ``todo_interactions``
row carrying ``payload.phase='prepare'``.

This module is intentionally pure: the I/O lives in ``runner.runner``. We
keep the JSON contract, prompt, and parser here so they can be unit-tested
without Supabase or Hermes.
"""
from __future__ import annotations

import json
import logging
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
    "  \"summary\": \"One short sentence describing the planned action.\",\n"
    "  \"kind\": \"task\" | \"cron\",\n"
    "  \"schedule\": \"Required when kind=cron. Hermes-style schedule string "
    "(e.g. '0 9 * * *', 'every 2h', '30m').\",\n"
    "  \"schedule_display\": \"Human-readable schedule for the UI when kind=cron "
    "(e.g. 'Every day at 9:00 AM').\",\n"
    "  \"tasks\": [\n"
    "    {\"title\": \"...\", \"connection_slug\": null, \"summary\": \"...\"}\n"
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
    "- Set kind=\"cron\" when the user wants a RECURRING automation on a "
    "schedule (daily email check, hourly monitoring, weekly reports). "
    "One-off tasks are kind=\"task\" (default). Cron jobs must include "
    "schedule and schedule_display; set ready=true unless the recurrence "
    "pattern itself is ambiguous.\n"
    "- CRITICAL kind examples (follow exactly):\n"
    "  * \"Every morning at 9am check email and create tasks\" → "
    "kind=cron, schedule=\"0 9 * * *\", schedule_display=\"Every day at 9:00 AM\"\n"
    "  * \"Check my inbox every 2 hours\" → kind=cron, schedule=\"every 2h\", "
    "schedule_display=\"Every 2 hours\"\n"
    "  * \"Send an email to John\" → kind=task (no schedule fields)\n"
    "  If the input mentions daily/hourly/weekly/every/each/recurring, "
    "kind MUST be cron — never kind=task for those.\n"
    "- Use \"tasks\" ONLY when the user's single input clearly contains "
    "multiple independent todos that should each get their own card. "
    "The first task stays on the original row; extras become separate "
    "already-prepared todos. Omit \"tasks\" or use a one-element array "
    "for a single task. Do not split a single coherent action.\n"
    "- Do NOT call tools. Do NOT write anything outside the JSON block.\n"
)


@dataclass
class PrepTask:
    """One task in a multi-task split."""

    title: str
    connection_slug: str | None = None
    summary: str | None = None


@dataclass
class PrepResult:
    """Parsed output of the preparation phase."""

    ready: bool
    kind: str = "task"
    title: str | None = None
    connection_slug: str | None = None
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
            t_summary = _clean_str(item.get("summary"), max_len=400)
            parsed_tasks.append(
                PrepTask(title=t_title, connection_slug=t_slug, summary=t_summary)
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
    lines = [
        "New todo to prepare (do NOT execute it):",
        task,
        "",
        f"Allowed connection_slug values: [{slugs}] or null.",
    ]
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
    base = "\n".join(lines)

    # Reuse the same Attachments block format as the execution prompt so the
    # agent recognizes it across phases.
    from .prompt import _append_attachments

    return _append_attachments(base, attachment_urls)


# Recurrence hints the model sometimes misses — used as a safety net.
_RECURRING_HINT = re.compile(
    r"\b("
    r"every|each|daily|hourly|weekly|monthly|recurring|"
    r"every\s+(?:morning|evening|night|week|day|hour)|"
    r"(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)\b"
    r")",
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


def infer_recurring_schedule(raw_text: str) -> tuple[str, str] | None:
    """Best-effort schedule inference from the user's raw input.

    Returns ``(schedule, schedule_display)`` or ``None`` if the text does not
    look recurring. Used when the prep model returns kind=task for an input
    that clearly asks for automation.
    """
    text = (raw_text or "").strip()
    if not text or not _RECURRING_HINT.search(text):
        return None
    lower = text.lower()

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

    # Generic recurrence without a parseable time — default to daily 9am.
    if _RECURRING_HINT.search(text):
        return ("0 9 * * *", "Every day at 9:00 AM")

    return None


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
