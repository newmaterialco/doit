"""Preflight support for on-demand browse.sh skill installs."""
from __future__ import annotations

import asyncio
import json
import logging
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)


def browse_skill_query_for_todo(todo: dict) -> str:
    parts = [
        todo.get("original_title") or "",
        todo.get("title") or "",
        todo.get("detail") or "",
        todo.get("preparation_summary") or "",
        todo.get("connection_slug") or "",
    ]
    return " ".join(part.strip() for part in parts if part and part.strip())[:1200]


def should_prefetch_browse_skill(query: str) -> bool:
    return bool(query.strip())


def _browse_skill_script_path(cfg: Any) -> Path:
    configured = getattr(cfg, "browse_skill_sync_script", "").strip()
    if configured:
        return Path(configured).expanduser()
    # Works from the source tree and from the VM layout where runner/ and
    # hermes/scripts/ are siblings below /opt/doit.
    return Path(__file__).resolve().parents[2] / "hermes" / "scripts" / "sync_browse_skill.py"


def _restart_hermes_profile(cfg: Any, profile_name: str) -> None:
    template = getattr(cfg, "hermes_restart_command_template", "").strip()
    if not template:
        log.info("Hermes restart skipped; HERMES_RESTART_COMMAND_TEMPLATE is empty")
        return
    command = template.format(profile=profile_name)
    subprocess.run(shlex.split(command), check=True, timeout=30)


def _sync_browse_skill_for_query(cfg: Any, query: str) -> dict[str, Any]:
    script = _browse_skill_script_path(cfg)
    if not script.exists():
        raise FileNotFoundError(f"browse skill sync script does not exist: {script}")
    timeout = float(getattr(cfg, "browse_skill_install_timeout_secs", 30))
    proc = subprocess.run(
        [
            sys.executable,
            str(script),
            "--query",
            query,
            "--timeout",
            str(timeout),
        ],
        check=True,
        text=True,
        capture_output=True,
        timeout=timeout + 10,
    )
    return json.loads(proc.stdout)


async def maybe_prefetch_browse_skill(
    cfg: Any,
    todo: dict,
    profile_name: str,
    *,
    allow_restart: bool = True,
) -> dict[str, Any] | None:
    """Install a matching browse.sh skill before the run starts.

    ``allow_restart=False`` is passed when the user has other Hermes runs in
    flight: a gateway restart would kill them, so a freshly-installed skill
    stays on disk but is not loaded (and not advertised in the prompt) for
    this run. The next restart picks it up.
    """
    if not getattr(cfg, "browse_skill_auto_install", False):
        return None
    query = browse_skill_query_for_todo(todo)
    if not query or not should_prefetch_browse_skill(query):
        return None

    try:
        result = await asyncio.to_thread(_sync_browse_skill_for_query, cfg, query)
    except Exception:
        log.warning("browse skill preflight failed; continuing without pre-install", exc_info=True)
        return None

    if result.get("installed"):
        log.info(
            "browse skill preflight installed name=%s slug=%s profile=%s",
            result.get("name"),
            result.get("slug"),
            profile_name,
        )
        if not allow_restart:
            log.info(
                "browse skill restart deferred: other runs in flight for "
                "profile=%s; skill loads on next restart",
                profile_name,
            )
            return None
        try:
            await asyncio.to_thread(_restart_hermes_profile, cfg, profile_name)
        except Exception:
            log.warning("failed to restart Hermes after browse skill install", exc_info=True)
        return result
    else:
        log.info(
            "browse skill preflight skipped reason=%s slug=%s profile=%s",
            result.get("reason"),
            result.get("slug"),
            profile_name,
        )
        if result.get("reason") == "already_current" and result.get("name"):
            return result
        return None
