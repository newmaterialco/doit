#!/usr/bin/env python3
"""Create a Composio v3 session MCP URL for a Hermes profile.

Run after adding a toolkit to the iOS Connections catalog. The iOS app
handles OAuth; Hermes only sees toolkits enabled here.

Usage:
    COMPOSIO_API_KEY=ak_... python create_composio_session.py <supabase-user-uuid>
"""
from __future__ import annotations

import json
import os
import sys

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
]


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <supabase-user-uuid>", file=sys.stderr)
        sys.exit(1)

    api_key = os.environ.get("COMPOSIO_API_KEY", "").strip()
    if not api_key:
        print("Set COMPOSIO_API_KEY in the environment.", file=sys.stderr)
        sys.exit(1)

    user_id = sys.argv[1].strip()
    from composio import Composio

    session = Composio(api_key=api_key).create(
        user_id=user_id,
        toolkits={"enable": TOOLKITS},
    )
    print("Paste into ~/.hermes/profiles/<profile>/config.yaml under mcp_servers.composio:")
    print()
    print("url:", session.mcp.url)
    print("headers:", json.dumps(dict(session.mcp.headers or {}), indent=2))
    print()
    print("Then restart the gateway: sudo systemctl restart hermes-<profile>")


if __name__ == "__main__":
    main()
