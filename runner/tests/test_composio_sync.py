"""Pure tests for Composio session sync helpers."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from runner.composio_sync import (
    _session_patch_payload,
    composio_session_id_for_profile,
    composio_session_id_from_config_text,
)


class ComposioSessionIdTests(unittest.TestCase):
    def test_extracts_session_id_from_mcp_url(self) -> None:
        text = """
mcp_servers:
  composio:
    url: "https://backend.composio.dev/tool_router/trs_abc123/mcp"
"""
        self.assertEqual(composio_session_id_from_config_text(text), "trs_abc123")

    def test_extracts_session_id_from_session_url_variant(self) -> None:
        text = "url: https://backend.composio.dev/tool_router/session/trs_xyz/mcp"
        self.assertEqual(composio_session_id_from_config_text(text), "trs_xyz")

    def test_missing_session_id_returns_none(self) -> None:
        self.assertIsNone(composio_session_id_from_config_text("url: https://example.com/mcp"))

    def test_reads_profile_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp) / "user_123"
            profile.mkdir()
            profile.joinpath("config.yaml").write_text(
                'url: "https://backend.composio.dev/tool_router/trs_file/mcp"',
                encoding="utf-8",
            )
            self.assertEqual(composio_session_id_for_profile(tmp, "user_123"), "trs_file")

    def test_missing_profile_config_returns_none(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(composio_session_id_for_profile(tmp, "missing"))

    def test_patch_payload_omits_empty_connected_accounts(self) -> None:
        payload = _session_patch_payload(
            connected_accounts={
                "github": ["ca_github"],
                "gmail": [],
                "unknown": ["ca_unknown"],
            },
            auth_configs={},
        )
        self.assertEqual(payload, {"connected_accounts": {"github": ["ca_github"]}})

    def test_patch_payload_keeps_auth_configs(self) -> None:
        payload = _session_patch_payload(
            connected_accounts={},
            auth_configs={"hunter": "auth_123"},
        )
        self.assertEqual(payload, {"auth_configs": {"hunter": "auth_123"}})


if __name__ == "__main__":
    unittest.main()
