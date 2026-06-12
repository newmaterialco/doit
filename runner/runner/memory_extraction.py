"""Post-task memory extraction helpers.

The task-running agent can still use Hermes' native ``memory`` tool, but Doit
now owns the product-level memory pipeline. After a task finishes, the runner
asks for a small JSON summary of durable facts learned during the task. The
caller decides whether to store high-confidence items as active memories or
surface them as suggestions.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Any, Literal

log = logging.getLogger(__name__)

MEMORY_OPEN = "[[DOIT_MEMORY]]"
MEMORY_CLOSE = "[[/DOIT_MEMORY]]"

_MEMORY_RE = re.compile(
    re.escape(MEMORY_OPEN) + r"\s*(\{.*?\})\s*" + re.escape(MEMORY_CLOSE),
    re.DOTALL,
)

MemoryTarget = Literal["user", "memory"]
MemoryConfidence = Literal["high", "medium", "low"]


MEMORY_EXTRACT_INSTRUCTIONS = (
    "You are Doit's memory extraction pass. You do not execute tasks and you "
    "do not call tools. Your only job is to inspect a completed task transcript "
    "and return durable memory candidates as strict JSON.\n\n"
    "Most useful memories start as clues, not commands. Look for durable facts "
    "that could help future tasks even when the user did not say \"remember\": "
    "preferences, communication style, work context, projects, teammates, "
    "important personal relationships, recurring people or places, identity "
    "facts, contact details, stable account/project context, workflow "
    "conventions, and corrections the user gave. Relationship labels such as "
    "\"my wife\", \"my husband\", \"my partner\", \"my assistant\", "
    "\"my manager\", or \"my coworker\" are strong clues that the named person "
    "may matter again.\n\n"
    "Stay conservative about confidence, not detection. Return plausible "
    "personal/work/life clues as medium-confidence memories with a clear reason "
    "so the user can later edit or forget them. Use high confidence only for explicit remember/save "
    "requests or clear reusable preferences such as \"change my signoff to "
    "Gabe\", \"make my emails shorter\", or \"when emailing Nick, keep it "
    "casual\".\n\n"
    "Skip truly one-off task details, draft/result content, temporary dates, "
    "secrets, OAuth tokens, API keys, passwords, raw logs, and facts already "
    "clearly represented in existing active memories.\n\n"
    "Return exactly one JSON object wrapped in these markers, with no prose:\n"
    f"{MEMORY_OPEN}\n"
    "{\n"
    "  \"memories\": [\n"
    "    {\n"
    "      \"target\": \"user\" | \"memory\",\n"
    "      \"title\": \"Short label, <= 120 chars; not the full fact\",\n"
    "      \"body\": \"One compact durable fact, <= 500 chars\",\n"
    "      \"confidence\": \"high\" | \"medium\" | \"low\",\n"
    "      \"reason\": \"Why this should be remembered, <= 240 chars\",\n"
    "      \"symbol_name\": \"SF Symbol for Passbook row, e.g. person.crop.circle, airplane, figure.hiking, envelope.fill\"\n"
    "    }\n"
    "  ]\n"
    "}\n"
    f"{MEMORY_CLOSE}\n\n"
    "The title should be a label like \"Birthday\", \"Preferred signoff\", "
    "or \"Wife's contact\", while body should contain the full remembered "
    "fact. Do not repeat the same sentence in title and body. "
    "Use target=\"user\" for user preferences, identity, communication style, "
    "contacts, and recurring personal context. Use target=\"memory\" for Doit's "
    "workflow notes, tool quirks, project conventions, and lessons learned. "
    "Pick symbol_name from Apple's SF Symbols that fits the memory topic "
    "(contact/person -> person.crop.circle, travel -> airplane, hiking -> "
    "figure.hiking, email -> envelope.fill, address/home -> house.fill, "
    "work/company -> building.2.fill). "
    "Return an empty memories array when nothing durable was learned."
)


@dataclass(frozen=True)
class MemoryCandidate:
    target: MemoryTarget
    title: str
    body: str
    confidence: MemoryConfidence
    reason: str
    symbol_name: str | None = None


def build_memory_extraction_prompt(
    *,
    todo: dict,
    task_context: dict[str, list[dict]],
    existing_memories: list[dict] | None = None,
    custom_instructions: str | None = None,
) -> str:
    """Build the narrow post-task memory extraction prompt."""
    lines = [
        "Completed Doit task:",
        f"Title: {_one_line(todo.get('title') or '')}",
    ]
    original = _one_line(todo.get("original_title") or "")
    if original and original != lines[-1]:
        lines.append(f"Original user request: {original}")
    detail = _one_line(todo.get("detail") or "")
    if detail:
        lines.append(f"Detail: {detail}")
    summary = _one_line(todo.get("preparation_summary") or "")
    if summary:
        lines.append(f"Preparation summary: {summary}")

    custom = _one_line(custom_instructions or "", limit=1000)
    if custom:
        lines += ["", "User memory instructions:", custom]

    if existing_memories:
        lines += ["", "Existing active memories:"]
        for row in existing_memories[:30]:
            title = _one_line(row.get("title") or "")
            body = _one_line(row.get("body") or "")
            target = row.get("target") or "user"
            if title or body:
                lines.append(f"- target={target}: {title}: {body}".strip())

    lines += ["", "Visible task transcript/context:"]
    messages = task_context.get("messages") or []
    if messages:
        lines.append("User messages:")
        for row in messages[-20:]:
            body = _one_line(row.get("body") or "", limit=600)
            if body:
                lines.append(f"- {body}")

    steps = task_context.get("steps") or []
    if steps:
        lines.append("Agent steps and results:")
        for row in steps[-40:]:
            kind = row.get("kind") or "step"
            tool = row.get("tool_name") or ""
            text = _one_line(row.get("text") or "", limit=700)
            if text:
                label = f"{kind}/{tool}" if tool else str(kind)
                lines.append(f"- {label}: {text}")

    artifacts = task_context.get("artifacts") or []
    if artifacts:
        lines.append("Artifacts:")
        for row in artifacts[-20:]:
            kind = row.get("kind") or "artifact"
            title = _one_line(row.get("title") or row.get("artifact_key") or "")
            if title:
                lines.append(f"- {kind}: {title}")

    lines += [
        "",
        "Extract durable memory candidates only. If the task contained a stable "
        "preference change like \"change my signoff to Gabe\", return it as a "
        "high-confidence user memory even though the user did not say remember. "
        "If the task mentioned relationship/contact/work/life context like "
        "\"my wife Alessandra\" or \"my manager Jordan\", return it as a "
        "medium-confidence user memory unless the user explicitly asked Doit "
        "to remember it.",
    ]
    return "\n".join(lines)


def parse_memory_extraction(text: str) -> list[MemoryCandidate]:
    if not text:
        return []
    match = _MEMORY_RE.search(text)
    if not match:
        return []
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError as e:
        log.warning("memory extraction JSON parse failed: %s", e)
        return []
    raw_memories = data.get("memories") if isinstance(data, dict) else None
    if not isinstance(raw_memories, list):
        return []

    candidates: list[MemoryCandidate] = []
    seen: set[tuple[str, str]] = set()
    for item in raw_memories:
        if not isinstance(item, dict):
            continue
        target = _clean_choice(item.get("target"), {"user", "memory"}, default="user")
        confidence = _clean_choice(
            item.get("confidence"),
            {"high", "medium", "low"},
            default="medium",
        )
        title = _clean_text(item.get("title"), max_len=120)
        body = _clean_text(item.get("body"), max_len=500)
        reason = _clean_text(item.get("reason"), max_len=240)
        symbol_name = _clean_text(item.get("symbol_name"), max_len=80) or None
        if not title or not body:
            continue
        if _canonical(title) == _canonical(body):
            title = _derive_short_title(body)
        key = (target, _canonical(body))
        if key in seen:
            continue
        seen.add(key)
        candidates.append(
            MemoryCandidate(
                target=target,  # type: ignore[arg-type]
                title=title,
                body=body,
                confidence=confidence,  # type: ignore[arg-type]
                reason=reason,
                symbol_name=symbol_name,
            )
        )
    return candidates


def storage_status_for_extracted_memory(_: MemoryCandidate) -> str:
    """Extracted memories are usable immediately; confidence remains metadata."""
    return "active"


def _clean_choice(value: Any, allowed: set[str], *, default: str) -> str:
    raw = str(value or "").strip().lower()
    return raw if raw in allowed else default


def _clean_text(value: Any, *, max_len: int) -> str:
    text = _one_line(str(value or ""), limit=max_len)
    return text.strip()


def _one_line(text: str, limit: int = 1000) -> str:
    collapsed = " ".join((text or "").split())
    return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"


def _canonical(text: str) -> str:
    return " ".join((text or "").lower().split())


def _derive_short_title(body: str) -> str:
    text = body.strip()
    lowered = text.lower()
    if "birthday" in lowered:
        return "Birthday"
    if "signoff" in lowered or "sign-off" in lowered or "sign off" in lowered:
        return "Preferred signoff"
    if "wife" in lowered:
        return "Wife"
    if "husband" in lowered:
        return "Husband"
    if "partner" in lowered:
        return "Partner"
    if "manager" in lowered:
        return "Manager"
    if "coworker" in lowered or "co-worker" in lowered:
        return "Coworker"
    if "email" in lowered:
        return "Email preference"
    if ":" in text:
        prefix = text.split(":", 1)[0].strip()
        for lead in ("User's ", "User "):
            if prefix.startswith(lead):
                prefix = prefix.removeprefix(lead).strip()
        if 2 <= len(prefix) <= 80:
            return prefix[:1].upper() + prefix[1:]
    words = text.rstrip(".").split()
    if len(words) <= 4:
        return text.rstrip(".")[:120]
    return "Memory"

