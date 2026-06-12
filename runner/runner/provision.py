"""Automated agent provisioning: turn a redeemed invite into a live Hermes gateway.

The iOS onboarding flow inserts a ``pending`` row into ``user_provisioning``
(via the ``onboarding`` Edge Function). The runner's main loop polls
``db.claim_next_provisioning_user()`` and runs :func:`provision_user` for
each claimed row. The steps mirror the old manual runbook in
``hermes/setup.md`` step 5, and every step is **idempotent** so re-running a
``failed`` user verifies/repairs partial state instead of duplicating it:

1. capacity guard (``MAX_PROVISIONED_USERS``)
2. profile name ``user_<first-8-of-uuid>`` (reused from ``user_hermes`` on repair)
3. profile dir + ``SOUL.md`` from ``hermes/profiles/_template/``
4. Composio v3 session (tool-router MCP URL) — skipped if config already has one
5. ``config.yaml`` (model block + Composio session + template body)
6. ``.env`` (unique port, generated ``API_SERVER_KEY``, Composio entity)
7. start the gateway via the systemd template unit (``hermes@<profile>``)
8. health-check ``/health`` with the bearer key
9. upsert ``user_hermes``; flip the provisioning row to ``ready``

Anything raising :class:`ProvisionError` (or any other exception) marks the
row ``failed`` with the message; a capacity refusal keeps it ``pending`` so
the user provisions automatically once room frees up.
"""
from __future__ import annotations

import logging
import re
import secrets
import shlex
import subprocess
import time
from pathlib import Path

import httpx

from .config import Config
from .db import DB
from .prepare import CONNECTION_SLUGS

log = logging.getLogger(__name__)

COMPOSIO_API = "https://backend.composio.dev"

# Toolkits enabled on every user's Composio session. Sourced from the same
# list the prep pass validates against (keep in sync with
# supabase/functions/integrations/index.ts CATALOG).
TOOLKITS: list[str] = sorted(CONNECTION_SLUGS)

# Toolkits that authenticate with an API key instead of OAuth; their auth
# config ids must be pinned on the session.
API_KEY_TOOLKITS = {"hunter"}

_CONFIG_PLACEHOLDER = "replace-with-session-mcp-url"

_HEALTH_TIMEOUT_SECS = 60.0
_HEALTH_POLL_SECS = 2.0


class ProvisionError(RuntimeError):
    """Provisioning failed at a specific step; message is user-loggable."""


class CapacityError(ProvisionError):
    """VM is at MAX_PROVISIONED_USERS; row should stay pending."""


# ---------------------------------------------------------------------------
# Composio session
# ---------------------------------------------------------------------------


def _items(payload) -> list[dict]:
    if isinstance(payload, list):
        return payload
    return payload.get("items") or payload.get("data") or []


def _composio_connection_context(
    api_key: str, user_id: str
) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Auth-config ids for API-key toolkits + the user's active connections.

    Ported from hermes/scripts/create_composio_session.py so provisioning
    needs no extra interpreter or venv.
    """
    headers = {"x-api-key": api_key}
    auth_configs: dict[str, str] = {}
    for slug in sorted(API_KEY_TOOLKITS):
        if slug not in TOOLKITS:
            continue
        res = httpx.get(
            f"{COMPOSIO_API}/api/v3/auth_configs",
            headers=headers,
            params={"toolkit_slug": slug, "limit": 10},
            timeout=30,
        )
        res.raise_for_status()
        configs = _items(res.json())
        api_key_configs = [c for c in configs if c.get("auth_scheme") == "API_KEY"]
        preferred = next(
            (c for c in api_key_configs if c.get("is_enabled_for_tool_router")),
            None,
        )
        chosen = preferred or (api_key_configs[0] if api_key_configs else None)
        if chosen and chosen.get("id"):
            auth_configs[slug] = chosen["id"]

    connected_accounts: dict[str, list[str]] = {}
    res = httpx.get(
        f"{COMPOSIO_API}/api/v3/connected_accounts",
        headers=headers,
        params={"user_ids": user_id, "limit": 100},
        timeout=30,
    )
    res.raise_for_status()
    for conn in _items(res.json()):
        if conn.get("status") != "ACTIVE":
            continue
        slug = (conn.get("toolkit") or {}).get("slug", "").lower()
        if slug in TOOLKITS and conn.get("id"):
            connected_accounts[slug] = [conn["id"]]

    return auth_configs, connected_accounts


def create_composio_session(api_key: str, user_id: str) -> tuple[str, dict[str, str]]:
    """Create a Composio v3 tool-router session; returns (mcp_url, headers)."""
    auth_configs, connected_accounts = _composio_connection_context(api_key, user_id)
    payload: dict = {
        "user_id": user_id,
        "toolkits": {"enable": TOOLKITS},
        "manage_connections": {
            "enable": True,
            "enable_wait_for_connections": False,
            "enable_connection_removal": True,
        },
        # Remote workbench stays disabled: it needs the proxy_execute
        # entitlement and gives the agent a broken path to prefer.
        "workbench": {"enable": False},
    }
    if auth_configs:
        payload["auth_configs"] = auth_configs
    if connected_accounts:
        payload["connected_accounts"] = connected_accounts

    res = httpx.post(
        f"{COMPOSIO_API}/api/v3.1/tool_router/session",
        headers={"x-api-key": api_key, "Content-Type": "application/json"},
        json=payload,
        timeout=60,
    )
    res.raise_for_status()
    data = res.json()
    mcp = data.get("mcp") or {}
    url = mcp.get("url")
    if not url:
        raise ProvisionError(f"Composio session response missing mcp.url: {data}")
    headers = dict(mcp.get("headers") or {}) or {"x-api-key": api_key}
    return str(url), {str(k): str(v) for k, v in headers.items()}


# ---------------------------------------------------------------------------
# Profile files
# ---------------------------------------------------------------------------


def profile_name_for_user(user_id: str) -> str:
    return f"user_{user_id.replace('-', '')[:8]}"


def template_dir(cfg: Config) -> Path:
    configured = (cfg.hermes_profile_template_dir or "").strip()
    if configured:
        return Path(configured).expanduser()
    # Source tree and VM layout both keep hermes/ as a sibling of runner/.
    return Path(__file__).resolve().parents[2] / "hermes" / "profiles" / "_template"


def render_config_yaml(
    cfg: Config,
    *,
    template_text: str,
    mcp_url: str,
    mcp_headers: dict[str, str],
) -> str:
    """Template config.yaml -> per-user config with model block + session."""
    text = template_text.replace(_CONFIG_PLACEHOLDER, mcp_url)
    # The template ships exactly one placeholder header value; replace it
    # with the first (typically only) session header.
    header_value = next(iter(mcp_headers.values()), "")
    text = text.replace("replace-with-session-mcp-header-value", header_value)
    header_name = next(iter(mcp_headers.keys()), "x-api-key")
    if header_name != "x-api-key":
        text = re.sub(
            r'^(\s*)x-api-key:(\s*".*")$',
            rf"\g<1>{header_name}:\g<2>",
            text,
            count=1,
            flags=re.MULTILINE,
        )
    model_block = (
        "model:\n"
        f"  default: {cfg.hermes_model_default}\n"
        f"  provider: {cfg.hermes_model_provider}\n"
        f"  base_url: {cfg.hermes_model_base_url}\n\n"
    )
    if not text.lstrip().startswith("model:"):
        text = model_block + text
    return text


def _render_env(
    existing: str,
    *,
    port: int,
    api_key: str,
    composio_api_key: str,
    user_id: str,
) -> str:
    """Merge required keys into a profile .env, preserving everything else."""
    required = {
        "API_SERVER_ENABLED": "true",
        "API_SERVER_HOST": "127.0.0.1",
        "API_SERVER_PORT": str(port),
        "API_SERVER_KEY": api_key,
        "COMPOSIO_API_KEY": composio_api_key,
        "COMPOSIO_ENTITY_ID": user_id,
    }
    lines = [
        line
        for line in existing.splitlines()
        if not any(line.startswith(f"{key}=") for key in required)
    ]
    lines.extend(f"{key}={value}" for key, value in required.items())
    return "\n".join(lines).strip() + "\n"


def _read_env_value(env_path: Path, key: str) -> str | None:
    if not env_path.exists():
        return None
    for line in env_path.read_text().splitlines():
        if line.startswith(f"{key}="):
            value = line.split("=", 1)[1].strip()
            return value or None
    return None


def _run_command(command: str, *, timeout: float = 60.0) -> None:
    log.info("provision: running %s", command)
    proc = subprocess.run(
        shlex.split(command),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise ProvisionError(
            f"command failed ({command!r}, exit {proc.returncode}): "
            f"{(proc.stderr or proc.stdout).strip()[:400]}"
        )


def _health_check(port: int, api_key: str) -> None:
    deadline = time.time() + _HEALTH_TIMEOUT_SECS
    last_error = "no response"
    url = f"http://127.0.0.1:{port}/health"
    while time.time() < deadline:
        try:
            res = httpx.get(
                url,
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=5,
            )
            if res.status_code == 200:
                return
            last_error = f"HTTP {res.status_code}"
        except Exception as e:  # connection refused while booting, etc.
            last_error = str(e)
        time.sleep(_HEALTH_POLL_SECS)
    raise ProvisionError(
        f"gateway health check failed on {url} after "
        f"{_HEALTH_TIMEOUT_SECS:.0f}s: {last_error}"
    )


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def provision_user(cfg: Config, db: DB, user_id: str) -> None:
    """Provision (or repair) one user's agent end to end. Blocking; the main
    loop runs this in a thread. Raises on failure — the caller owns status
    transitions."""
    if not cfg.composio_api_key:
        raise ProvisionError(
            "COMPOSIO_API_KEY is not set in the runner .env; "
            "the provisioner cannot create Composio sessions."
        )

    existing = db.get_user_hermes(user_id)
    if existing is None and db.count_user_hermes() >= cfg.max_provisioned_users:
        raise CapacityError(
            f"VM is at MAX_PROVISIONED_USERS={cfg.max_provisioned_users}; "
            "raise the limit (and capacity) to provision more users."
        )

    profile_name = (
        existing.profile_name if existing else profile_name_for_user(user_id)
    )
    profiles_dir = Path(cfg.hermes_profiles_dir).expanduser()
    profile_dir = profiles_dir / profile_name
    tpl = template_dir(cfg)
    if not tpl.exists():
        raise ProvisionError(f"profile template dir does not exist: {tpl}")

    # 1. Profile directory. `hermes profile create` registers the profile
    #    with the CLI; tolerate failure (already exists) and ensure the
    #    directory layout ourselves.
    if not profile_dir.exists():
        try:
            _run_command(f"{cfg.hermes_bin} profile create {profile_name}")
        except Exception as e:
            log.warning(
                "hermes profile create failed (continuing with mkdir): %s", e
            )
    (profile_dir / "memories").mkdir(parents=True, exist_ok=True)

    # 2. SOUL.md (persona) — copy once, never overwrite.
    soul_path = profile_dir / "SOUL.md"
    if not soul_path.exists():
        soul_path.write_text((tpl / "SOUL.md").read_text())

    # 3. config.yaml with a real Composio session. If the file already has a
    #    non-placeholder session URL (repair pass), keep it — sessions are
    #    stable and re-creating one would orphan the old URL.
    config_path = profile_dir / "config.yaml"
    needs_session = (
        not config_path.exists()
        or _CONFIG_PLACEHOLDER in config_path.read_text()
    )
    if needs_session:
        mcp_url, mcp_headers = create_composio_session(
            cfg.composio_api_key, user_id
        )
        config_path.write_text(
            render_config_yaml(
                cfg,
                template_text=(tpl / "config.yaml").read_text(),
                mcp_url=mcp_url,
                mcp_headers=mcp_headers,
            )
        )

    # 4. .env: stable port + API key. Reuse whatever already exists (DB row
    #    first, then the .env on disk) so repairs never rotate credentials
    #    out from under a half-provisioned gateway.
    env_path = profile_dir / ".env"
    api_key = (
        (existing.api_key if existing else None)
        or _read_env_value(env_path, "API_SERVER_KEY")
        or secrets.token_hex(32)
    )
    port = (
        (existing.port if existing else None)
        or _int_or_none(_read_env_value(env_path, "API_SERVER_PORT"))
        or _allocate_port(cfg, db)
    )
    env_text = _render_env(
        env_path.read_text() if env_path.exists() else "",
        port=port,
        api_key=api_key,
        composio_api_key=cfg.composio_api_key,
        user_id=user_id,
    )
    env_path.write_text(env_text)
    env_path.chmod(0o600)

    # 5. Start (or restart) the gateway under the systemd template unit and
    #    wait for /health. A repair pass restarts so config/.env edits load.
    _run_command(cfg.hermes_start_command_template.format(profile=profile_name))
    try:
        _health_check(port, api_key)
    except ProvisionError:
        # The unit may have been running with stale config; restart once.
        log.info("provision: health check failed; restarting %s", profile_name)
        _run_command(
            cfg.hermes_restart_command_template.format(profile=profile_name)
        )
        _health_check(port, api_key)

    # 6. Publish the mapping. From this moment the runner can claim todos
    #    for the user.
    db.upsert_user_hermes(
        user_id=user_id,
        profile_name=profile_name,
        api_host="127.0.0.1",
        api_port=port,
        api_key=api_key,
        composio_entity=user_id,
    )
    log.info(
        "provisioned user=%s profile=%s port=%d", user_id, profile_name, port
    )


def _int_or_none(value: str | None) -> int | None:
    try:
        return int(value) if value else None
    except ValueError:
        return None


def _allocate_port(cfg: Config, db: DB) -> int:
    highest = db.max_user_hermes_port()
    if highest is None:
        return cfg.hermes_port_range_start
    return max(highest + 1, cfg.hermes_port_range_start)


def run_provisioning(cfg: Config, db: DB, row: dict) -> None:
    """Status-transition wrapper around :func:`provision_user`.

    ``ready`` on success, ``failed`` + error message on failure, back to
    ``pending`` (with the message in ``error``) on a capacity refusal so the
    user provisions automatically once room frees up.
    """
    user_id = str(row["user_id"])
    log.info("provisioning user %s (invite=%s)", user_id, row.get("invite_code"))
    try:
        provision_user(cfg, db, user_id)
    except CapacityError as e:
        log.warning("provisioning capacity refusal for %s: %s", user_id, e)
        db.update_user_provisioning(
            user_id,
            {"status": "pending", "error": str(e), "claimed_at": None},
        )
        return
    except Exception as e:
        log.exception("provisioning failed for %s", user_id)
        db.update_user_provisioning(
            user_id,
            {"status": "failed", "error": str(e)[:500]},
        )
        return
    db.update_user_provisioning(user_id, {"status": "ready", "error": None})
