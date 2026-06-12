"""Tests for the provisioner's pure helpers (no network, no subprocess)."""
from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

from runner.provision import (
    _allocate_port,
    _render_env,
    profile_name_for_user,
    render_config_yaml,
)

_TEMPLATE = Path(__file__).resolve().parents[2] / "hermes" / "profiles" / "_template"


class _FakeCfg:
    hermes_model_default = "anthropic/claude-opus-4.6"
    hermes_model_provider = "nous"
    hermes_model_base_url = "https://openrouter.ai/api/v1"
    hermes_port_range_start = 8643


class ProfileNameTests(unittest.TestCase):
    def test_uses_first_eight_uuid_chars(self) -> None:
        self.assertEqual(
            profile_name_for_user("a1b2c3d4-e5f6-7890-abcd-ef0123456789"),
            "user_a1b2c3d4",
        )


class RenderConfigTests(unittest.TestCase):
    def test_replaces_placeholders_and_prepends_model_block(self) -> None:
        template_text = _TEMPLATE.joinpath("config.yaml").read_text()
        out = render_config_yaml(
            _FakeCfg(),
            template_text=template_text,
            mcp_url="https://backend.composio.dev/tool_router/trs_abc/mcp",
            mcp_headers={"x-api-key": "secret-123"},
        )
        self.assertNotIn("replace-with-session-mcp-url", out)
        self.assertNotIn("replace-with-session-mcp-header-value", out)
        self.assertIn("trs_abc/mcp", out)
        self.assertIn("secret-123", out)
        self.assertTrue(out.lstrip().startswith("model:"))
        self.assertIn("provider: nous", out)
        # Template body (memory limits etc.) survives.
        self.assertIn("memory_enabled: true", out)

    def test_existing_model_block_not_duplicated(self) -> None:
        text = 'model:\n  default: x\n\nmcp_servers:\n  composio:\n    url: "replace-with-session-mcp-url"\n'
        out = render_config_yaml(
            _FakeCfg(),
            template_text=text,
            mcp_url="https://example.com/mcp",
            mcp_headers={"x-api-key": "k"},
        )
        self.assertEqual(out.count("model:"), 1)


class RenderEnvTests(unittest.TestCase):
    def test_fresh_env_contains_required_keys(self) -> None:
        out = _render_env(
            "",
            port=8650,
            api_key="abc",
            composio_api_key="ck_test",
            user_id="uuid-1",
        )
        self.assertIn("API_SERVER_ENABLED=true", out)
        self.assertIn("API_SERVER_PORT=8650", out)
        self.assertIn("API_SERVER_KEY=abc", out)
        self.assertIn("COMPOSIO_ENTITY_ID=uuid-1", out)

    def test_merge_preserves_unrelated_lines_and_overrides_ours(self) -> None:
        existing = (
            "# comment kept\n"
            "CUSTOM_FLAG=1\n"
            "API_SERVER_PORT=9999\n"
            "API_SERVER_KEY=old\n"
        )
        out = _render_env(
            existing,
            port=8650,
            api_key="new",
            composio_api_key="ck",
            user_id="u",
        )
        self.assertIn("# comment kept", out)
        self.assertIn("CUSTOM_FLAG=1", out)
        self.assertIn("API_SERVER_PORT=8650", out)
        self.assertNotIn("9999", out)
        self.assertIn("API_SERVER_KEY=new", out)
        self.assertNotIn("API_SERVER_KEY=old", out)


class AllocatePortTests(unittest.TestCase):
    def test_first_user_gets_range_start(self) -> None:
        db = mock.Mock()
        db.max_user_hermes_port.return_value = None
        self.assertEqual(_allocate_port(_FakeCfg(), db), 8643)

    def test_next_port_is_max_plus_one(self) -> None:
        db = mock.Mock()
        db.max_user_hermes_port.return_value = 8651
        self.assertEqual(_allocate_port(_FakeCfg(), db), 8652)

    def test_never_below_range_start(self) -> None:
        db = mock.Mock()
        db.max_user_hermes_port.return_value = 5000
        self.assertEqual(_allocate_port(_FakeCfg(), db), 8643)


if __name__ == "__main__":
    unittest.main()
