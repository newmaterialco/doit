#!/usr/bin/env python3
"""Mint single-use invite codes for a waitlist CSV.

Uses the admin Edge Function create_invite action when ADMIN_SECRET is set.
Otherwise inserts directly into invite_codes with the service role key (same
rows the dashboard creates).

Usage:
    export ADMIN_SECRET='...'   # preferred
    # or: export SUPABASE_SERVICE_ROLE_KEY='...'
    python3 scripts/bulk-mint-invites.py \\
        --input "/path/to/waitlist.csv" \\
        --output "/path/to/waitlist-invites.csv"
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://qjeutitqgdsasccxfxdy.supabase.co/functions/v1/admin"
DEFAULT_REST_URL = "https://qjeutitqgdsasccxfxdy.supabase.co/rest/v1/invite_codes"
DEFAULT_ANON = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFqZXV0aXRxZ2RzYXNjY3hmeGR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTMzNjksImV4cCI6MjA5NTU4OTM2OX0."
    "j2yU_6HTLh6WJaPUFsG3vdgd0cK6VHFXm6XYW_cb26U"
)
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def generate_invite_code() -> str:
    suffix = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
    return f"DOIT-{suffix}"


def http_json(
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    body: dict | None = None,
) -> tuple[int, dict | list | str]:
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers = {**headers, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            if not raw:
                return resp.status, {}
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = raw
        return exc.code, parsed


def read_rows(path: Path, skip_filled: bool) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        rows: list[dict[str, str]] = []
        for row in reader:
            email = (row.get("Email") or row.get("email") or "").strip()
            if not email:
                continue
            code = (row.get("Invite Code") or row.get("invite_code") or "").strip()
            if skip_filled and code:
                rows.append({"email": email, "code": code})
            else:
                rows.append({"email": email, "code": ""})
        return rows


def unique_emails_to_mint(rows: list[dict[str, str]]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for row in rows:
        if row["code"]:
            continue
        key = row["email"].lower()
        if key in seen:
            continue
        seen.add(key)
        ordered.append(row["email"])
    return ordered


def create_invite_admin(
    *,
    url: str,
    admin_secret: str,
    anon_key: str,
    email: str,
) -> str:
    status, data = http_json(
        "POST",
        url,
        headers={
            "Authorization": f"Bearer {anon_key}",
            "apikey": anon_key,
            "X-Admin-Secret": admin_secret,
        },
        body={"action": "create_invite", "note": email, "max_uses": 1},
    )
    if status != 200:
        raise RuntimeError(f"HTTP {status}: {data}")
    if isinstance(data, dict) and "error" in data:
        raise RuntimeError(str(data.get("detail") or data["error"]))
    if not isinstance(data, dict):
        raise RuntimeError(f"unexpected response: {data}")
    code = (data.get("invite") or {}).get("code")
    if not code:
        raise RuntimeError(f"missing invite.code in response: {data}")
    return str(code)


def create_invite_rest(
    *,
    rest_url: str,
    service_role_key: str,
    email: str,
) -> str:
    for _ in range(2):
        code = generate_invite_code()
        status, data = http_json(
            "POST",
            rest_url,
            headers={
                "Authorization": f"Bearer {service_role_key}",
                "apikey": service_role_key,
                "Prefer": "return=representation",
            },
            body={"code": code, "note": email, "max_uses": 1},
        )
        if status in (200, 201) and isinstance(data, list) and data:
            return str(data[0].get("code") or code)
        if status == 409:
            continue
        raise RuntimeError(f"HTTP {status}: {data}")
    raise RuntimeError("failed to mint unique code after retries")


def write_output(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["Email", "Invite Code"])
        writer.writeheader()
        for row in rows:
            writer.writerow({"Email": row["email"], "Invite Code": row["code"]})


def fetch_summary_admin(url: str, admin_secret: str, anon_key: str) -> dict:
    status, data = http_json(
        "POST",
        url,
        headers={
            "Authorization": f"Bearer {anon_key}",
            "apikey": anon_key,
            "X-Admin-Secret": admin_secret,
        },
        body={"action": "summary"},
    )
    if status != 200 or not isinstance(data, dict):
        raise RuntimeError(f"summary failed: HTTP {status} {data}")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description="Bulk mint waitlist invite codes")
    parser.add_argument("--input", type=Path, required=True, help="Input CSV path")
    parser.add_argument("--output", type=Path, help="Output CSV path")
    parser.add_argument("--url", default=DEFAULT_URL, help="Admin function URL")
    parser.add_argument("--rest-url", default=DEFAULT_REST_URL, help="invite_codes REST URL")
    parser.add_argument("--anon-key", default=DEFAULT_ANON, help="Supabase anon key")
    parser.add_argument(
        "--admin-secret",
        default=os.environ.get("ADMIN_SECRET", ""),
        help="ADMIN_SECRET (or set env var)",
    )
    parser.add_argument(
        "--service-role-key",
        default=os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""),
        help="Service role key fallback (or set env var)",
    )
    parser.add_argument("--delay-ms", type=int, default=100, help="Delay between API calls")
    parser.add_argument(
        "--skip-filled",
        action="store_true",
        help="Skip rows that already have an Invite Code in the input CSV",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print mint plan without calling the API",
    )
    parser.add_argument(
        "--errors",
        type=Path,
        help="Write failed emails to this CSV (default: <output>.errors.csv)",
    )
    args = parser.parse_args()

    if not args.input.exists():
        print(f"input not found: {args.input}", file=sys.stderr)
        return 1

    rows = read_rows(args.input, skip_filled=args.skip_filled)
    if not rows:
        print("no emails found in input CSV", file=sys.stderr)
        return 1

    to_mint = unique_emails_to_mint(rows)
    already_filled = sum(1 for r in rows if r["code"])
    print(f"rows: {len(rows)} | already filled: {already_filled} | to mint: {len(to_mint)}")

    if args.dry_run:
        for email in to_mint:
            print(f"would mint: {email}")
        return 0

    use_admin = bool(args.admin_secret)
    use_rest = bool(args.service_role_key)
    if not use_admin and not use_rest:
        print(
            "ADMIN_SECRET or SUPABASE_SERVICE_ROLE_KEY is required",
            file=sys.stderr,
        )
        return 1

    if not args.output:
        print("--output is required unless --dry-run", file=sys.stderr)
        return 1

    mode = "admin API" if use_admin else "service role REST"
    print(f"mode: {mode}")

    errors_path = args.errors or args.output.with_suffix(args.output.suffix + ".errors.csv")
    code_by_email: dict[str, str] = {}
    for row in rows:
        if row["code"]:
            code_by_email[row["email"].lower()] = row["code"]

    failed: list[dict[str, str]] = []
    delay_s = max(0, args.delay_ms) / 1000.0

    for i, email in enumerate(to_mint, start=1):
        try:
            if use_admin:
                code = create_invite_admin(
                    url=args.url,
                    admin_secret=args.admin_secret,
                    anon_key=args.anon_key,
                    email=email,
                )
            else:
                code = create_invite_rest(
                    rest_url=args.rest_url,
                    service_role_key=args.service_role_key,
                    email=email,
                )
            code_by_email[email.lower()] = code
            print(f"[{i}/{len(to_mint)}] {email} -> {code}")
        except Exception as exc:
            print(f"[{i}/{len(to_mint)}] FAILED {email}: {exc}", file=sys.stderr)
            failed.append({"email": email, "error": str(exc)})
        if delay_s and i < len(to_mint):
            time.sleep(delay_s)

    for row in rows:
        if not row["code"]:
            row["code"] = code_by_email.get(row["email"].lower(), "")

    write_output(args.output, rows)
    print(f"wrote {args.output}")

    if failed:
        with errors_path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=["email", "error"])
            writer.writeheader()
            writer.writerows(failed)
        print(f"errors: {len(failed)} (see {errors_path})", file=sys.stderr)
        return 2

    missing = sum(1 for r in rows if not r["code"])
    if missing:
        print(f"warning: {missing} rows have no code in output", file=sys.stderr)
        return 2

    if use_admin:
        try:
            summary = fetch_summary_admin(args.url, args.admin_secret, args.anon_key)
            print(f"unused_invites: {summary.get('unused_invites')}")
        except Exception as exc:
            print(f"summary check skipped: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
