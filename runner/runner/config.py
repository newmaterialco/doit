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
    openrouter_api_key: str
    browserbase_api_key: str
    browserbase_project_id: str
    browse_skill_auto_install: bool
    browse_skill_install_timeout_secs: float
    browse_skill_min_confidence: float
    browse_skill_sync_script: str
    apns_key_path: str
    apns_key_id: str
    apns_team_id: str
    apns_topic: str
    apns_use_sandbox: bool
    poll_interval_secs: float
    run_timeout_secs: float
    stall_timeout_secs: float
    browser_silence_timeout_secs: float
    max_concurrent_runs: int
    max_runs_per_user: int
    # --- Automated provisioning (see runner/provision.py) ---
    provisioner_enabled: bool
    composio_api_key: str
    max_provisioned_users: int
    hermes_port_range_start: int
    hermes_bin: str
    hermes_start_command_template: str
    hermes_profile_template_dir: str
    hermes_model_provider: str
    hermes_model_default: str
    hermes_model_base_url: str
    hermes_user_char_limit: int
    hermes_memory_char_limit: int
    memory_consolidate_with_model: bool
    byo_connector_mode: bool
    connector_token: str
    connector_user_id: str
    connector_hermes_url: str
    connector_hermes_api_key: str
    connector_profile_name: str


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
            "sudo systemctl restart hermes@{profile}",
        ),
        openai_api_key=os.environ.get("OPENAI_API_KEY", ""),
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
        openrouter_api_key=os.environ.get("OPENROUTER_API_KEY", ""),
        browserbase_api_key=os.environ.get("BROWSERBASE_API_KEY", ""),
        browserbase_project_id=os.environ.get("BROWSERBASE_PROJECT_ID", ""),
        browse_skill_auto_install=_bool("BROWSE_SKILL_AUTO_INSTALL", default=False),
        browse_skill_install_timeout_secs=float(os.environ.get("BROWSE_SKILL_INSTALL_TIMEOUT_SECS", "30")),
        browse_skill_min_confidence=float(os.environ.get("BROWSE_SKILL_MIN_CONFIDENCE", "0")),
        browse_skill_sync_script=os.environ.get("BROWSE_SKILL_SYNC_SCRIPT", ""),
        apns_key_path=os.environ.get("APNS_KEY_PATH", ""),
        apns_key_id=os.environ.get("APNS_KEY_ID", ""),
        apns_team_id=os.environ.get("APNS_TEAM_ID", ""),
        apns_topic=os.environ.get("APNS_TOPIC", ""),
        apns_use_sandbox=_bool("APNS_USE_SANDBOX", default=True),
        poll_interval_secs=float(os.environ.get("POLL_INTERVAL_SECS", "2")),
        run_timeout_secs=float(os.environ.get("RUN_TIMEOUT_SECS", "900")),
        # Progress watchdog: how long without any SSE progress (tool events,
        # thoughts, text) before the live activity flips to "stalled" so the
        # user isn't staring at a frozen card.
        stall_timeout_secs=float(os.environ.get("STALL_TIMEOUT_SECS", "120")),
        # Browser tools can legitimately go quiet while a page loads, but a
        # much longer silence usually means Browserbase or site automation is
        # stuck. Fail clearly before the generic whole-run timeout.
        browser_silence_timeout_secs=float(
            os.environ.get("BROWSER_SILENCE_TIMEOUT_SECS", "300")
        ),
        # Worker pool size: how many work items (todos, cron runs, prep
        # passes) may be in flight at once across all users. 1 reproduces
        # the historical strictly-sequential behavior.
        max_concurrent_runs=int(os.environ.get("MAX_CONCURRENT_RUNS", "8")),
        # Per-user execution cap so one user can't occupy the whole pool.
        # Their extra todos simply stay `requested` until a slot frees up.
        max_runs_per_user=int(os.environ.get("MAX_RUNS_PER_USER", "2")),
        # --- Automated provisioning ---
        # The provisioner also requires COMPOSIO_API_KEY; without it the
        # loop logs a warning and leaves rows pending.
        provisioner_enabled=_bool("PROVISIONER_ENABLED", default=True),
        composio_api_key=os.environ.get("COMPOSIO_API_KEY", ""),
        # Hard ceiling on provisioned agents so a leaked invite code can't
        # melt the VM. Raise deliberately as capacity is validated.
        max_provisioned_users=int(os.environ.get("MAX_PROVISIONED_USERS", "100")),
        hermes_port_range_start=int(os.environ.get("HERMES_PORT_RANGE_START", "8643")),
        hermes_bin=os.environ.get("HERMES_BIN", "hermes"),
        hermes_start_command_template=os.environ.get(
            "HERMES_START_COMMAND_TEMPLATE",
            "sudo systemctl enable --now hermes@{profile}",
        ),
        # Defaults to <repo>/hermes/profiles/_template next to the runner.
        hermes_profile_template_dir=os.environ.get("HERMES_PROFILE_TEMPLATE_DIR", ""),
        # Model block written into new profiles (setup.md step 5/3c).
        hermes_model_provider=os.environ.get("HERMES_MODEL_PROVIDER", "openrouter"),
        hermes_model_default=os.environ.get(
            "HERMES_MODEL_DEFAULT", "google/gemini-2.5-flash"
        ),
        hermes_model_base_url=os.environ.get(
            "HERMES_MODEL_BASE_URL", "https://openrouter.ai/api/v1"
        ),
        hermes_user_char_limit=int(
            os.environ.get("HERMES_USER_CHAR_LIMIT", str(4000))
        ),
        hermes_memory_char_limit=int(
            os.environ.get("HERMES_MEMORY_CHAR_LIMIT", str(8000))
        ),
        memory_consolidate_with_model=_bool("MEMORY_CONSOLIDATE_WITH_MODEL", default=False),
        byo_connector_mode=_bool("BYO_CONNECTOR_MODE", default=False),
        connector_token=os.environ.get("DOIT_CONNECTOR_TOKEN", ""),
        connector_user_id=os.environ.get("DOIT_CONNECTOR_USER_ID", ""),
        connector_hermes_url=os.environ.get("DOIT_CONNECTOR_HERMES_URL", "http://127.0.0.1:8643"),
        connector_hermes_api_key=os.environ.get("DOIT_CONNECTOR_HERMES_API_KEY", ""),
        connector_profile_name=os.environ.get("DOIT_CONNECTOR_PROFILE_NAME", "byo-hermes"),
    )
