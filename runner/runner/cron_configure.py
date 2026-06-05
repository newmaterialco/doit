"""Configuration pass for scheduled cron jobs.

After a cron job is created (or when the user sends chat in the detail
view), a lightweight Hermes pass refines the prompt/schedule and may ask
one clarifying question (delivery channel, timing, etc.) before the job
is enabled.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any

from .prepare import CONNECTION_SLUGS, _clean_option, _clean_str

log = logging.getLogger(__name__)

CONFIG_OPEN = "[[DOIT_CRON_CONFIG]]"
CONFIG_CLOSE = "[[/DOIT_CRON_CONFIG]]"

_CONFIG_RE = re.compile(
    re.escape(CONFIG_OPEN) + r"\s*(\{.*?\})\s*" + re.escape(CONFIG_CLOSE),
    re.DOTALL,
)

CRON_CONFIG_INSTRUCTIONS = (
    "You are the CONFIGURATION pass for a scheduled automation (cron job). "
    "You will NOT execute the task and you will NOT call any tools. Your job "
    "is to finalize how this recurring automation should run and emit one "
    "structured JSON block.\n\n"
    "Output exactly one JSON object wrapped between these markers, with no "
    "surrounding prose:\n"
    f"{CONFIG_OPEN}\n"
    "{\n"
    "  \"name\": \"Short card title (<= 110 chars)\",\n"
    "  \"prompt\": \"Self-contained instruction the agent runs each time "
    "(include delivery target once known, e.g. Slack channel, email, Google Doc)\",\n"
    "  \"schedule\": \"Hermes-style schedule (e.g. '0 9 * * *', 'every 2h')\",\n"
    "  \"schedule_display\": \"UI label (e.g. 'Daily at 9:00 AM', "
    "'Every 2 hours', 'Mondays at 3:00 PM')\",\n"
    "  \"connection_slug\": \"<allowed slug or null>\",\n"
    "  \"summary\": \"One sentence describing the configured automation.\",\n"
    "  \"ready\": true | false,\n"
    "  \"clarification\": {\n"
    "    \"prompt\": \"Single question if ready=false\",\n"
    "    \"options\": [{\"id\": \"...\", \"label\": \"...\", "
    "\"style\": \"primary\"|\"secondary\"|\"destructive\"}],\n"
    "    \"allow_freeform\": true,\n"
    "    \"freeform_placeholder\": \"Optional hint\"\n"
    "  }\n"
    "}\n"
    f"{CONFIG_CLOSE}\n\n"
    "Rules:\n"
    "- Ask ONE clarifying question when something essential is missing "
    "(where to deliver a digest, which Slack channel, which email address). "
    "Set ready=false with options like Google Doc / Email / Slack when "
    "delivery is unspecified.\n"
    "- Prefer ready=true when defaults are reasonable.\n"
    "- schedule_display must read naturally in a UI pill: 'Daily at 9:00 AM', "
    "'Mondays at 3:00 PM', 'Every 2 hours'.\n"
    "- Wall-clock cron times are evaluated in the user's local timezone "
    "(captured when they created this job). Treat \"9am\" as 9am local; "
    "do NOT convert to UTC.\n"
    "- The prompt must be self-contained for unattended runs — include "
    "delivery instructions once the user has chosen.\n"
    "- Pick connection_slug only from allowed slugs in the prompt.\n"
    "- Do NOT call tools. Do NOT write anything outside the JSON block.\n"
)


@dataclass
class CronConfigResult:
    ready: bool
    name: str | None = None
    prompt: str | None = None
    schedule: str | None = None
    schedule_display: str | None = None
    connection_slug: str | None = None
    summary: str | None = None
    clarification_prompt: str | None = None
    clarification_options: list[dict[str, Any]] = field(default_factory=list)
    clarification_allow_freeform: bool = True
    clarification_placeholder: str | None = None

    @property
    def needs_clarification(self) -> bool:
        return not self.ready and bool(self.clarification_prompt)


def parse_cron_config(
    text: str,
    allowed_slugs: frozenset[str] | set[str] = CONNECTION_SLUGS,
) -> CronConfigResult | None:
    if not text:
        return None
    match = _CONFIG_RE.search(text)
    if not match:
        return None
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError as e:
        log.warning("cron config JSON parse failed: %s", e)
        return None
    if not isinstance(data, dict):
        return None

    name = _clean_str(data.get("name"), max_len=200)
    prompt = _clean_str(data.get("prompt"), max_len=4000)
    schedule = _clean_str(data.get("schedule"), max_len=120)
    schedule_display = _clean_str(data.get("schedule_display"), max_len=200)
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
        ready = True

    return CronConfigResult(
        ready=ready,
        name=name,
        prompt=prompt,
        schedule=schedule,
        schedule_display=schedule_display,
        connection_slug=slug,
        summary=summary,
        clarification_prompt=c_prompt,
        clarification_options=c_options,
        clarification_allow_freeform=c_allow_freeform,
        clarification_placeholder=c_placeholder,
    )


def build_cron_config_prompt(
    *,
    name: str,
    prompt: str,
    schedule: str,
    schedule_display: str | None,
    original_prompt: str | None,
    allowed_slugs: frozenset[str] | set[str] = CONNECTION_SLUGS,
    prior: dict[str, Any] | None = None,
    pending_messages: list[str] | None = None,
) -> str:
    slugs = ", ".join(sorted(allowed_slugs))
    lines = [
        "Scheduled automation to configure (do NOT run it yet):",
        f"Title: {name}",
        f"Schedule: {schedule}",
    ]
    if schedule_display:
        lines.append(f"Schedule display: {schedule_display}")
    lines.append(f"Task prompt: {prompt}")
    if original_prompt and original_prompt.strip() and original_prompt.strip() != prompt.strip():
        lines.append(f"Original user request: {original_prompt.strip()}")
    lines += ["", f"Allowed connection_slug values: [{slugs}] or null."]

    if pending_messages:
        lines += ["", "New messages from the user since last configure pass:"]
        for body in pending_messages:
            stripped = body.strip()
            if not stripped:
                continue
            for line in stripped.splitlines():
                lines.append(f"  > {line}")

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
            "Incorporate their answer into the prompt and finalize. "
            "Set ready=true unless something materially new is still missing."
        )

    return "\n".join(lines)
