#!/usr/bin/env python3
"""Smoke-test intra-user concurrency: N simultaneous /v1/runs on ONE profile.

Verifies the assumption the concurrent runner is built on: a single Hermes
gateway can execute multiple runs in parallel as long as each has its own
session_id (the runner uses doit-todo-<uuid> per todo).

Run ON THE VM with the runner venv's python (httpx installed):

    /opt/doit/runner/.venv/bin/python /opt/doit/scripts/smoke-concurrent-runs.py \
        --profile <profile> [--runs 2] [--timeout 180]

Reads API_SERVER_PORT / API_SERVER_KEY from the profile's .env. Sends
trivial no-tool prompts, so it costs a few hundred tokens total. Exits 0
only if every run reaches run.completed.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

import httpx

TERMINAL_OK = {"run.completed"}
TERMINAL_FAIL = {"run.failed", "response.failed", "error"}


def read_profile_env(profile: str) -> tuple[int, str]:
    env_path = Path.home() / ".hermes" / "profiles" / profile / ".env"
    if not env_path.exists():
        sys.exit(f"profile env not found: {env_path}")
    port = 0
    key = ""
    for raw in env_path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("API_SERVER_PORT="):
            port = int(line.split("=", 1)[1].strip().strip("'\""))
        elif line.startswith("API_SERVER_KEY="):
            key = line.split("=", 1)[1].strip().strip("'\"")
    if not port or not key:
        sys.exit(f"API_SERVER_PORT / API_SERVER_KEY missing in {env_path}")
    return port, key


async def one_run(client: httpx.AsyncClient, idx: int, timeout: float) -> dict:
    word = f"smoke{idx}"
    session_id = f"doit-smoke-{int(time.time())}-{idx}"
    started = time.monotonic()
    resp = await client.post(
        "/v1/runs",
        json={
            "input": f"Reply with exactly the single word {word} and nothing else. Do not use any tools.",
            "instructions": "You are a test probe. Answer with the requested word only.",
            "session_id": session_id,
        },
    )
    resp.raise_for_status()
    run_id = resp.json().get("run_id") or resp.json().get("id")
    print(f"[{idx}] started run_id={run_id} session={session_id}", flush=True)

    result = {
        "idx": idx,
        "run_id": run_id,
        "ok": False,
        "event": None,
        "events_seen": [],
        "final_status": None,
        "secs": None,
    }
    try:
        async with asyncio.timeout(timeout):
            async with client.stream("GET", f"/v1/runs/{run_id}/events") as stream:
                stream.raise_for_status()
                async for line in stream.aiter_lines():
                    if not line.startswith("event:"):
                        continue
                    event_name = line.split(":", 1)[1].strip()
                    if event_name not in result["events_seen"]:
                        result["events_seen"].append(event_name)
                    if event_name in TERMINAL_OK:
                        result["ok"] = True
                        result["event"] = event_name
                        break
                    if event_name in TERMINAL_FAIL:
                        result["event"] = event_name
                        break
    except TimeoutError:
        result["event"] = "timeout"

    # The stream can close before/without a terminal event; the run record
    # is authoritative for a short window afterwards.
    if not result["ok"]:
        try:
            run = (await client.get(f"/v1/runs/{run_id}")).json()
            result["final_status"] = run.get("status")
            if result["final_status"] in ("completed", "succeeded", "done"):
                result["ok"] = True
        except httpx.HTTPError as e:
            result["final_status"] = f"fetch-failed: {e}"
    result["secs"] = round(time.monotonic() - started, 1)
    print(f"[{idx}] finished ok={result['ok']} event={result['event']} in {result['secs']}s", flush=True)
    return result


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()

    port, key = read_profile_env(args.profile)
    print(f"profile={args.profile} port={port} runs={args.runs}", flush=True)

    async with httpx.AsyncClient(
        base_url=f"http://127.0.0.1:{port}",
        headers={"Authorization": f"Bearer {key}"},
        timeout=httpx.Timeout(connect=10.0, read=None, write=30.0, pool=30.0),
    ) as client:
        health = await client.get("/health")
        health.raise_for_status()
        results = await asyncio.gather(
            *(one_run(client, i, args.timeout) for i in range(args.runs))
        )

    print(json.dumps(results, indent=2))
    if all(r["ok"] for r in results):
        print(f"SMOKE PASS: {len(results)} concurrent runs completed on one profile")
    else:
        sys.exit("SMOKE FAIL: at least one run did not complete")


if __name__ == "__main__":
    asyncio.run(main())
