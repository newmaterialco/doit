"""SF Symbol selection for Passbook memory rows."""
from __future__ import annotations

import re

DEFAULT_SYMBOL = "menucard"
_SYMBOL_MAX_LEN = 80
_SYMBOL_RE = re.compile(r"[^a-z0-9.]")

_KEYWORD_RULES: tuple[tuple[tuple[str, ...], str], ...] = (
    (("contact", "phone", "associate", "wife", "husband", "partner", "manager", "coworker", "full name"), "person.crop.circle"),
    (("flight", "travel", "airport", "relocation", "relocate", "london move", "trip"), "airplane"),
    (("hik", "yellowstone", "outdoor", "trail", "mountain", "camp"), "figure.hiking"),
    (("email", "inbox", "signoff", "sign-off", "sign off"), "envelope.fill"),
    (("address", "san francisco", "redwood", "storage", "apartment", "home"), "house.fill"),
    (("company", "client", "business", "consultancy", "new material"), "building.2.fill"),
    (("fish", "fishing", "fly fishing"), "fish.fill"),
    (("coffee", "tea", "latte", "drink"), "cup.and.saucer.fill"),
    (("calendar", "schedule", "weekday"), "calendar"),
    (("research", "subreddit", "reddit"), "magnifyingglass"),
    (("ai", "robotics", "training data", "niche"), "cpu"),
)


def sanitize_symbol_name(raw: str | None) -> str | None:
    if raw is None:
        return None
    cleaned = _SYMBOL_RE.sub("", raw.strip().lower())
    if not cleaned or cleaned == "." or len(cleaned) > _SYMBOL_MAX_LEN:
        return None
    return cleaned


def infer_memory_symbol(title: str, body: str) -> str:
    haystack = f"{title} {body}".lower()
    for keywords, symbol in _KEYWORD_RULES:
        if any(keyword in haystack for keyword in keywords):
            return symbol
    return DEFAULT_SYMBOL


def resolve_memory_symbol(
    *,
    symbol_name: str | None,
    title: str,
    body: str,
) -> str:
    clean = sanitize_symbol_name(symbol_name)
    if clean:
        return clean
    return infer_memory_symbol(title, body)
