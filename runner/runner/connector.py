"""BYO Hermes connector entrypoint.

Runs beside a user's existing Hermes gateway and processes only the Supabase
work paired to that connector token.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import time
from contextlib import suppress
from datetime import datetime, timezone
from urllib.parse import urlparse

from .connector_api import ConnectorAPI
from .events import translate
from .hermes import HermesClient, HermesEndpoint
from .prompt import build_prompt, session_id_for_todo, session_key_for_user
from .runner import setup_logging
from .scheduler import TaskPool, UserGates

log = logging.getLogger(__name__)

_HEARTBEAT_INTERVAL_SECS = 15.0
_STALE_SCAN_INTERVAL_SECS = 30.0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Doit BYO Hermes connector")
    parser.add_argument("--supabase-url", required=True)
    parser.add_argument("--supabase-anon-key", default=os.environ.get("SUPABASE_ANON_KEY", ""))
    parser.add_argument("--connector-token", required=True)
    parser.add_argument("--hermes-url", default="http://127.0.0.1:8643")
    parser.add_argument("--hermes-api-key", default=os.environ.get("HERMES_API_KEY", ""))
    parser.add_argument("--profile-name", default="byo-hermes")
    parser.add_argument("--poll-interval-secs", type=float, default=float(os.environ.get("POLL_INTERVAL_SECS", "2")))
    parser.add_argument("--max-concurrent-runs", type=int, default=int(os.environ.get("MAX_CONCURRENT_RUNS", "1")))
    return parser.parse_args()


def _endpoint_parts(url: str) -> tuple[str, int]:
    parsed = urlparse(url)
    if parsed.scheme != "http":
        raise RuntimeError("Hermes URL must start with http://")
    if not parsed.hostname:
        raise RuntimeError("Hermes URL is missing a host")
    default_port = 443 if parsed.scheme == "https" else 80
    return parsed.hostname, parsed.port or default_port


def _capabilities() -> dict[str, str]:
    return {
        "Hermes": "reachable",
        "Models": "managed by your Hermes",
        "Memory": "local to your Hermes profile",
        "Integrations": "managed by your Hermes",
    }


async def _heartbeat_loop(api: ConnectorAPI, *, profile_name: str, endpoint_url: str) -> None:
    capabilities = {
        "Hermes": "reachable",
        "Models": "managed by your Hermes",
        "Memory": "local to your Hermes profile",
        "Integrations": "managed by your Hermes",
    }
    while True:
        await api.heartbeat(
            profile_name=profile_name,
            endpoint_url=endpoint_url,
            capabilities=capabilities,
        )
        await asyncio.sleep(_HEARTBEAT_INTERVAL_SECS)


async def _lease_loop(api: ConnectorAPI, todo_id: str) -> None:
    while True:
        await asyncio.sleep(60)
        await api.touch_lease(todo_id)


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


async def _run_todo(
    api: ConnectorAPI,
    *,
    endpoint: HermesEndpoint,
    todo: dict,
) -> None:
    todo_id = str(todo["id"])
    user_id = str(todo["user_id"])
    title = str(todo.get("title") or "")
    detail = str(todo.get("detail") or "")
    original_title = str(todo.get("original_title") or "")
    prompt = build_prompt(
        title,
        detail,
        original_title=original_title,
        preparation_summary=todo.get("preparation_summary"),
        connection_slug=todo.get("connection_slug"),
        topic=todo.get("topic"),
    )
    session_id = session_id_for_todo(user_id, todo_id)
    session_key = session_key_for_user(user_id)
    hermes = HermesClient(endpoint)
    lease = asyncio.create_task(_lease_loop(api, todo_id))
    terminal_status: str | None = None
    try:
        await api.insert_step(
            todo_id=todo_id,
            kind="thought",
            text="Starting task with your Hermes connector.",
        )
        run_id = await hermes.start_run(prompt, session_id=session_id, session_key=session_key)
        await api.update_todo(
            todo_id,
            {"hermes_run_id": run_id, "hermes_session_id": session_id},
        )
        async for event in hermes.stream_events(run_id):
            effect = translate(event.event, event.data)
            if effect is None:
                continue
            if effect.step_kind:
                await api.insert_step(
                    todo_id=todo_id,
                    kind=effect.step_kind,
                    text=effect.text,
                    url=effect.url,
                    tool_name=effect.tool_name,
                )
            if effect.new_status:
                terminal_status = effect.new_status
                fields: dict[str, object] = {"status": effect.new_status}
                if effect.new_status == "failed":
                    fields["error_message"] = effect.text or "Hermes run failed."
                if effect.new_status == "done":
                    fields["completed_at"] = _iso_now()
                await api.update_todo(todo_id, fields)
                if effect.new_status in {"done", "failed", "needs_auth", "needs_input"}:
                    break
        if terminal_status is None:
            await api.insert_step(todo_id=todo_id, kind="final", text="Done.")
            await api.update_todo(todo_id, {"status": "done", "completed_at": _iso_now()})
    except Exception as exc:
        log.exception("BYO connector task failed todo=%s", todo_id)
        with suppress(Exception):
            await api.insert_step(todo_id=todo_id, kind="error", text=str(exc))
            await api.update_todo(todo_id, {"status": "failed", "error_message": str(exc)})
    finally:
        lease.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await lease
        await hermes.aclose()


async def connector_loop() -> None:
    setup_logging()
    args = _parse_args()
    if not args.supabase_anon_key:
        raise RuntimeError("missing --supabase-anon-key")

    api = ConnectorAPI(
        supabase_url=args.supabase_url,
        supabase_anon_key=args.supabase_anon_key,
        connector_token=args.connector_token,
    )
    host, port = _endpoint_parts(args.hermes_url)
    endpoint = HermesEndpoint(
        profile_name=args.profile_name,
        host=host,
        port=port,
        api_key=args.hermes_api_key,
    )
    await api.register(
        profile_name=args.profile_name,
        endpoint_url=args.hermes_url,
        capabilities=_capabilities(),
    )

    gates = UserGates()
    pool = TaskPool(max(1, args.max_concurrent_runs))
    heartbeat = asyncio.create_task(
        _heartbeat_loop(
            api,
            profile_name=args.profile_name,
            endpoint_url=args.hermes_url,
        )
    )
    last_stale_scan = 0.0

    log.info("BYO connector online endpoint=%s", args.hermes_url)
    try:
        while True:
            if not pool.has_capacity:
                await pool.wait_for_capacity(args.poll_interval_secs)
                continue

            now = time.time()
            todo = None
            if now - last_stale_scan >= _STALE_SCAN_INTERVAL_SECS:
                last_stale_scan = now
                todo = await api.recover_stale()
            if todo is None:
                todo = await api.claim_next()
            if todo is not None:
                pool.spawn(
                    _run_todo(api, endpoint=endpoint, todo=todo),
                    name=f"byo-todo:{todo['id']}",
                )
                continue

            await asyncio.sleep(args.poll_interval_secs)
    finally:
        heartbeat.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await heartbeat


def main() -> None:
    asyncio.run(connector_loop())


if __name__ == "__main__":
    main()
