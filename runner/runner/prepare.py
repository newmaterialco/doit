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
from dataclasses import dataclass, field
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
    "- Do NOT call tools. Do NOT write anything outside the JSON block.\n"
)


@dataclass
class PrepResult:
    """Parsed output of the preparation phase."""

    ready: bool
    title: str | None = None
    connection_slug: str | None = None
    summary: str | None = None
    clarification_prompt: str | None = None
    clarification_options: list[dict[str, Any]] = field(default_factory=list)
    clarification_allow_freeform: bool = True
    clarification_placeholder: str | None = None

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
        title=title,
        connection_slug=slug,
        summary=summary,
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
) -> str:
    """Build the per-todo input the runner sends to Hermes for preparation.

    ``prior`` is the previously-responded prep interaction, if the user
    answered a clarifying question and we are re-running preparation. It
    must look like a row from ``todo_interactions``: at least ``prompt``,
    ``payload``, and ``response``.
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
    return "\n".join(lines)


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
