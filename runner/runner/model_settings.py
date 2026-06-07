"""Apply user-selected model settings to local Hermes profile files."""
from __future__ import annotations

import logging
import os
import shlex
import subprocess
from pathlib import Path

from .config import Config
from .db import AgentModelSetting

log = logging.getLogger(__name__)

KEY_ENV_BY_PROVIDER = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
}

KEY_VALUE_ATTR_BY_PROVIDER = {
    "openai": "openai_api_key",
    "anthropic": "anthropic_api_key",
    "openrouter": "openrouter_api_key",
}

HERMES_PROVIDER_BY_PROVIDER = {
    "openai": "openai-api",
    "anthropic": "anthropic",
    "openrouter": "openrouter",
}


class AgentModelApplier:
    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._profiles_dir = Path(cfg.hermes_profiles_dir).expanduser()
        self._restart_template = cfg.hermes_restart_command_template

    def apply(self, profile_name: str, setting: AgentModelSetting) -> None:
        provider = HERMES_PROVIDER_BY_PROVIDER.get(setting.provider)
        key_env = KEY_ENV_BY_PROVIDER.get(setting.provider)
        key_attr = KEY_VALUE_ATTR_BY_PROVIDER.get(setting.provider)
        if provider is None or key_env is None or key_attr is None:
            raise RuntimeError(f"Unsupported model provider: {setting.provider}")
        api_key = getattr(self._cfg, key_attr)
        if not api_key:
            raise RuntimeError(f"Doit is missing its global {key_env} for {setting.provider}.")

        profile_dir = self._profiles_dir / profile_name
        if not profile_dir.exists():
            raise RuntimeError(f"Hermes profile directory does not exist: {profile_dir}")

        self._write_config(profile_dir / "config.yaml", provider, setting.model)
        self._write_env(profile_dir / ".env", key_env, api_key)
        self._restart(profile_name)
        log.info(
            "applied model setting profile=%s provider=%s model=%s",
            profile_name,
            setting.provider,
            setting.model,
        )

    def _write_config(self, path: Path, provider: str, model: str) -> None:
        existing = path.read_text() if path.exists() else ""
        model_block = "\n".join(
            [
                "model:",
                f"  provider: {provider}",
                f"  default: {model}",
            ]
        )
        updated = _replace_top_level_block(existing, "model", model_block)
        _atomic_write(path, updated)

    def _write_env(self, path: Path, key_env: str, api_key: str) -> None:
        lines = path.read_text().splitlines() if path.exists() else []
        supported_keys = set(KEY_ENV_BY_PROVIDER.values())
        kept = [
            line
            for line in lines
            if not any(line.startswith(f"{name}=") for name in supported_keys)
        ]
        kept.append(f"{key_env}={api_key}")
        _atomic_write(path, "\n".join(kept).rstrip() + "\n", mode=0o600)

    def _restart(self, profile_name: str) -> None:
        if not self._restart_template.strip():
            log.info("Hermes restart skipped; HERMES_RESTART_COMMAND_TEMPLATE is empty")
            return
        command = self._restart_template.format(profile=profile_name)
        subprocess.run(shlex.split(command), check=True, timeout=30)


def _replace_top_level_block(existing: str, key: str, block: str) -> str:
    lines = existing.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line == f"{key}:":
            i += 1
            while i < len(lines):
                current = lines[i]
                if current and not current.startswith((" ", "\t")):
                    break
                i += 1
            continue
        out.append(line)
        i += 1

    rest = "\n".join(out).lstrip("\n")
    return f"{block}\n\n{rest}".rstrip() + "\n"


def _atomic_write(path: Path, content: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content)
    if mode is not None:
        os.chmod(tmp, mode)
    elif path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o777)
    tmp.replace(path)
