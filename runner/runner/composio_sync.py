"""Composio connection preflight and per-user MCP session sync.

The iOS Connections screen can show a toolkit as connected while Hermes still
uses an older Composio tool-router session that lacks the connected_account id.
Before starting a run that expects a Composio toolkit, sync the current user's
active connections into the exact session id in their Hermes profile config.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx

from .config import Config
from .prepare import CONNECTION_SLUGS

log = logging.getLogger(__name__)

COMPOSIO_API = "https://backend.composio.dev"
TOOLKITS: list[str] = sorted(CONNECTION_SLUGS)
API_KEY_TOOLKITS: set[str] = set()

_SESSION_RE = re.compile(
    r"tool_router/(?:session/)?(trs_[A-Za-z0-9_-]+)(?:/mcp)?"
)


@dataclass(frozen=True)
class ComposioPreflightResult:
    """Outcome of checking a toolkit before a Hermes run."""

    checked: bool
    connected: bool
    synced: bool = False
    toolkit: str | None = None
    session_id: str | None = None
    connection_id: str | None = None
    redirect_url: str | None = None
    error: str | None = None


def composio_session_id_from_config_text(text: str) -> str | None:
    """Extract the Composio tool-router session id from profile config YAML."""
    match = _SESSION_RE.search(text or "")
    return match.group(1) if match else None


def composio_session_id_for_profile(
    profiles_dir: str | Path,
    profile_name: str,
) -> str | None:
    path = Path(profiles_dir).expanduser() / profile_name / "config.yaml"
    try:
        return composio_session_id_from_config_text(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        log.warning("Composio preflight: config.yaml missing for profile=%s", profile_name)
        return None
    except Exception as e:
        log.warning("Composio preflight: failed reading %s: %s", path, e)
        return None


async def ensure_composio_connection(
    cfg: Config,
    *,
    profile_name: str,
    user_id: str,
    toolkit: str,
) -> ComposioPreflightResult:
    """Verify and sync a user's Composio toolkit before a Hermes run.

    Missing configuration is non-fatal: return `checked=False` so the runner
    can continue with Hermes' normal OAuth handling. A definite disconnected
    account returns `checked=True, connected=False` plus a best-effort redirect
    URL for the app's auth UI.
    """
    slug = (toolkit or "").strip().lower()
    if not slug or slug not in CONNECTION_SLUGS:
        return ComposioPreflightResult(checked=False, connected=False, toolkit=slug)
    if not cfg.composio_api_key:
        return ComposioPreflightResult(
            checked=False,
            connected=False,
            toolkit=slug,
            error="COMPOSIO_API_KEY is not configured",
        )

    session_id = composio_session_id_for_profile(cfg.hermes_profiles_dir, profile_name)
    if not session_id:
        return ComposioPreflightResult(
            checked=False,
            connected=False,
            toolkit=slug,
            error="Composio session id not found in Hermes profile config",
        )

    headers = {"x-api-key": cfg.composio_api_key, "Content-Type": "application/json"}
    try:
        async with httpx.AsyncClient(
            base_url=COMPOSIO_API,
            headers=headers,
            timeout=httpx.Timeout(connect=10.0, read=30.0, write=10.0, pool=10.0),
        ) as client:
            connected_accounts = await _list_active_connected_accounts(client, user_id)
            auth_configs = await _auth_configs_for_session(client)
            connection_id = connected_accounts.get(slug, [None])[0]
            synced = await _patch_session(
                client,
                session_id=session_id,
                connected_accounts=connected_accounts,
                auth_configs=auth_configs,
            )
            if connection_id:
                return ComposioPreflightResult(
                    checked=True,
                    connected=True,
                    synced=synced,
                    toolkit=slug,
                    session_id=session_id,
                    connection_id=connection_id,
                )
            redirect_url = await _create_link(client, session_id=session_id, toolkit=slug)
            return ComposioPreflightResult(
                checked=True,
                connected=False,
                synced=synced,
                toolkit=slug,
                session_id=session_id,
                redirect_url=redirect_url,
            )
    except Exception as e:
        log.warning(
            "Composio preflight failed user=%s profile=%s toolkit=%s: %s",
            user_id,
            profile_name,
            slug,
            e,
        )
        return ComposioPreflightResult(
            checked=False,
            connected=False,
            toolkit=slug,
            session_id=session_id,
            error=str(e),
        )


async def _list_active_connected_accounts(
    client: httpx.AsyncClient,
    user_id: str,
) -> dict[str, list[str]]:
    res = await client.get(
        "/api/v3/connected_accounts",
        params={"user_ids": user_id, "limit": 100},
    )
    res.raise_for_status()
    connected: dict[str, list[str]] = {}
    for conn in _items(res.json()):
        if conn.get("status") != "ACTIVE":
            continue
        slug = str(((conn.get("toolkit") or {}).get("slug") or conn.get("appName") or "")).lower()
        conn_id = str(conn.get("id") or "")
        if slug in TOOLKITS and conn_id:
            connected[slug] = [conn_id]
    return connected


async def _auth_configs_for_session(client: httpx.AsyncClient) -> dict[str, str]:
    auth_configs: dict[str, str] = {}
    for slug in sorted(API_KEY_TOOLKITS):
        res = await client.get(
            "/api/v3/auth_configs",
            params={"toolkit_slug": slug, "limit": 10},
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
            auth_configs[slug] = str(chosen["id"])
    return auth_configs


async def _patch_session(
    client: httpx.AsyncClient,
    *,
    session_id: str,
    connected_accounts: dict[str, list[str]],
    auth_configs: dict[str, str],
) -> bool:
    patch = _session_patch_payload(
        connected_accounts=connected_accounts,
        auth_configs=auth_configs,
    )
    if not patch:
        return False
    res = await client.patch(f"/api/v3.1/tool_router/session/{session_id}", json=patch)
    if not res.is_success:
        log.warning(
            "Composio preflight session patch failed session=%s status=%s body=%s",
            session_id,
            res.status_code,
            res.text[:400],
        )
        res.raise_for_status()
    return True


def _session_patch_payload(
    *,
    connected_accounts: dict[str, list[str]],
    auth_configs: dict[str, str],
) -> dict[str, Any]:
    patch: dict[str, Any] = {}
    if auth_configs:
        patch["auth_configs"] = auth_configs
    active_connections = {
        slug: ids
        for slug, ids in connected_accounts.items()
        if slug in TOOLKITS and ids
    }
    # Composio's PATCH endpoint accepts sparse updates. Sending every enabled
    # toolkit with [] can be rejected, so only send active connections here.
    if active_connections:
        patch["connected_accounts"] = active_connections
    return patch


async def _create_link(
    client: httpx.AsyncClient,
    *,
    session_id: str,
    toolkit: str,
) -> str | None:
    res = await client.post(
        f"/api/v3.1/tool_router/session/{session_id}/link",
        json={"toolkit": toolkit},
    )
    if not res.is_success:
        log.warning(
            "Composio preflight link failed session=%s toolkit=%s status=%s body=%s",
            session_id,
            toolkit,
            res.status_code,
            res.text[:400],
        )
        return None
    data = res.json()
    url = data.get("redirect_url") or data.get("redirectUrl") or data.get("link")
    return str(url) if url else None


def _items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    items = payload.get("items") or payload.get("data") or []
    return [item for item in items if isinstance(item, dict)]
