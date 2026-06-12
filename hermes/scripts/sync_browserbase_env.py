#!/usr/bin/env python3
"""Copy Browserbase credentials from runner/.env into ~/.hermes/.env.

Hermes reads Browserbase credentials from the global Hermes env file, while
Doit's runner keeps the operator-facing secret template in runner/.env. Run
this on the VM after adding or rotating Browserbase credentials:

    python hermes/scripts/sync_browserbase_env.py --restart
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
from pathlib import Path

KEYS = (
    "BROWSERBASE_API_KEY",
    "BROWSERBASE_PROJECT_ID",
    "BROWSERBASE_PROXIES",
    "BROWSERBASE_KEEP_ALIVE",
    "BROWSER_INACTIVITY_TIMEOUT",
)


def _parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key in KEYS:
            values[key] = _unquote(value.strip())
    return values


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _format_env_line(key: str, value: str) -> str:
    if any(ch.isspace() for ch in value) or "#" in value:
        return f"{key}={shlex.quote(value)}"
    return f"{key}={value}"


def _write_hermes_env(path: Path, values: dict[str, str]) -> None:
    lines = path.read_text().splitlines() if path.exists() else []
    kept = [
        line
        for line in lines
        if not any(line.startswith(f"{key}=") for key in KEYS)
    ]
    if kept and kept[-1].strip():
        kept.append("")
    kept.append("# Browserbase (managed browser automation)")
    for key in KEYS:
        value = values.get(key)
        if value:
            kept.append(_format_env_line(key, value))

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text("\n".join(kept).rstrip() + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def _restart_hermes_units() -> None:
    units = subprocess.run(
        ["systemctl", "list-units", "--type=service", "--all", "--no-legend"],
        check=True,
        text=True,
        capture_output=True,
    )
    # Both hermes@<profile> template instances and any leftover legacy
    # hermes-<profile> units.
    names = [
        line.split()[0]
        for line in units.stdout.splitlines()
        if line.split()
        and (
            line.split()[0].startswith("hermes@")
            or line.split()[0].startswith("hermes-")
        )
    ]
    if not names:
        print("No hermes gateway systemd units found to restart.")
        return
    subprocess.run(["sudo", "systemctl", "restart", *names], check=True)
    print("Restarted:", ", ".join(names))


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=repo_root / "runner" / ".env",
        help="Runner .env file containing Browserbase credentials.",
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=Path.home() / ".hermes" / ".env",
        help="Global Hermes .env file to update.",
    )
    parser.add_argument(
        "--restart",
        action="store_true",
        help="Restart all hermes gateway systemd units after updating the env file.",
    )
    args = parser.parse_args()

    if not args.source.exists():
        raise SystemExit(f"Source env file does not exist: {args.source}")

    values = _parse_env(args.source)
    missing = [key for key in ("BROWSERBASE_API_KEY", "BROWSERBASE_PROJECT_ID") if not values.get(key)]
    if missing:
        raise SystemExit(f"Missing required Browserbase keys in {args.source}: {', '.join(missing)}")

    _write_hermes_env(args.target.expanduser(), values)
    print(f"Updated {args.target.expanduser()} with Browserbase credentials.")

    if args.restart:
        _restart_hermes_units()
    else:
        print("Restart Hermes gateways to pick up the new env: sudo systemctl restart hermes@<profile>")


if __name__ == "__main__":
    main()
