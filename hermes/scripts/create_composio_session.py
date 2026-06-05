#!/usr/bin/env python3
"""Create or refresh a Composio v3 session MCP URL for a Hermes profile.

Run after adding a toolkit to the iOS Connections catalog, or after a user
connects an API-key integration (e.g. Hunter). Pass --patch to update the
existing session in config.yaml without changing the MCP URL.

Usage:
    COMPOSIO_API_KEY=ak_... python create_composio_session.py <supabase-user-uuid>
    COMPOSIO_API_KEY=ak_... python create_composio_session.py <uuid> --patch ~/.hermes/profiles/gabriel/config.yaml
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import httpx

# Keep in sync with supabase/functions/integrations/index.ts CATALOG and
# runner/runner/prepare.py CONNECTION_SLUGS.
TOOLKITS = [
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
]

API_KEY_TOOLKITS = {"hunter"}
COMPOSIO_API = "https://backend.composio.dev"


def _items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return payload
    return payload.get("items") or payload.get("data") or []


def _connection_context(
    api_key: str, user_id: str, toolkits: list[str]
) -> tuple[dict[str, str], dict[str, list[str]]]:
    headers = {"x-api-key": api_key}
    auth_configs: dict[str, str] = {}
    for slug in API_KEY_TOOLKITS:
        if slug not in toolkits:
            continue
        res = httpx.get(
            f"{COMPOSIO_API}/api/v3/auth_configs",
            headers=headers,
            params={"toolkit_slug": slug, "limit": 10},
            timeout=30,
        )
        res.raise_for_status()
        configs = _items(res.json())
        api_key_configs = [
            c for c in configs if c.get("auth_scheme") == "API_KEY"
        ]
        preferred = next(
            (c for c in api_key_configs if c.get("is_enabled_for_tool_router")), None
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
        if slug in toolkits and conn.get("id"):
            connected_accounts[slug] = [conn["id"]]

    return auth_configs, connected_accounts


def _session_payload(user_id: str, toolkits: list[str], api_key: str) -> dict[str, Any]:
    auth_configs, connected_accounts = _connection_context(api_key, user_id, toolkits)
    payload: dict[str, Any] = {
        "user_id": user_id,
        "toolkits": {"enable": toolkits},
        "manage_connections": {
            "enable": True,
            "enable_wait_for_connections": False,
            "enable_connection_removal": True,
        },
    }
    if auth_configs:
        payload["auth_configs"] = auth_configs
    if connected_accounts:
        payload["connected_accounts"] = connected_accounts
    return payload


def _session_id_from_config(path: Path) -> str | None:
    text = path.read_text()
    match = re.search(r"tool_router/(trs_[^/]+)/mcp", text)
    return match.group(1) if match else None


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <supabase-user-uuid> [--patch config.yaml]", file=sys.stderr)
        sys.exit(1)

    api_key = os.environ.get("COMPOSIO_API_KEY", "").strip()
    if not api_key:
        print("Set COMPOSIO_API_KEY in the environment.", file=sys.stderr)
        sys.exit(1)

    user_id = sys.argv[1].strip()
    patch_config = sys.argv[2] == "--patch" and len(sys.argv) == 4
    config_path = Path(sys.argv[3]) if patch_config else None

    headers = {"x-api-key": api_key, "Content-Type": "application/json"}
    payload = _session_payload(user_id, TOOLKITS, api_key)

    if patch_config:
        assert config_path is not None
        session_id = _session_id_from_config(config_path)
        if not session_id:
            print(f"No composio session id found in {config_path}", file=sys.stderr)
            sys.exit(1)
        patch_body = {
            k: payload[k]
            for k in ("auth_configs", "connected_accounts")
            if payload.get(k)
        }
        res = httpx.patch(
            f"{COMPOSIO_API}/api/v3.1/tool_router/session/{session_id}",
            headers=headers,
            json=patch_body,
            timeout=30,
        )
        res.raise_for_status()
        print(f"Patched session {session_id}")
        print("connected_accounts:", json.dumps(payload.get("connected_accounts") or {}, indent=2))
        print("Then restart the gateway: sudo systemctl restart hermes-<profile>")
        return

    from composio import Composio

    session = Composio(api_key=api_key).create(
        user_id=user_id,
        toolkits={"enable": TOOLKITS},
        auth_configs=payload.get("auth_configs"),
        connected_accounts=payload.get("connected_accounts"),
    )
    print("Paste into ~/.hermes/profiles/<profile>/config.yaml under mcp_servers.composio:")
    print()
    print("url:", session.mcp.url)
    print("headers:", json.dumps(dict(session.mcp.headers or {}), indent=2))
    print()
    print("connected_accounts:", json.dumps(payload.get("connected_accounts") or {}, indent=2))
    print()
    print("Then restart the gateway: sudo systemctl restart hermes-<profile>")


if __name__ == "__main__":
    main()
