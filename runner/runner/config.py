"""Runner configuration loaded from environment."""
from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv

load_dotenv()


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"missing required env var: {name}")
    return value


def _bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "y", "on"}


@dataclass(frozen=True)
class Config:
    supabase_url: str
    supabase_service_role_key: str
    hermes_profiles_dir: str
    hermes_restart_command_template: str
    openai_api_key: str
    anthropic_api_key: str
    apns_key_path: str
    apns_key_id: str
    apns_team_id: str
    apns_topic: str
    apns_use_sandbox: bool
    poll_interval_secs: float
    run_timeout_secs: float


def load() -> Config:
    return Config(
        supabase_url=_required("SUPABASE_URL"),
        supabase_service_role_key=_required("SUPABASE_SERVICE_ROLE_KEY"),
        hermes_profiles_dir=os.environ.get(
            "HERMES_PROFILES_DIR",
            os.path.expanduser("~/.hermes/profiles"),
        ),
        hermes_restart_command_template=os.environ.get(
            "HERMES_RESTART_COMMAND_TEMPLATE",
            "sudo systemctl restart hermes-{profile}",
        ),
        openai_api_key=os.environ.get("OPENAI_API_KEY", ""),
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
        apns_key_path=os.environ.get("APNS_KEY_PATH", ""),
        apns_key_id=os.environ.get("APNS_KEY_ID", ""),
        apns_team_id=os.environ.get("APNS_TEAM_ID", ""),
        apns_topic=os.environ.get("APNS_TOPIC", ""),
        apns_use_sandbox=_bool("APNS_USE_SANDBOX", default=True),
        poll_interval_secs=float(os.environ.get("POLL_INTERVAL_SECS", "2")),
        run_timeout_secs=float(os.environ.get("RUN_TIMEOUT_SECS", "900")),
    )
