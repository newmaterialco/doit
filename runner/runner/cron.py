"""Run due cron jobs and configure new/edited schedules."""
from __future__ import annotations

import asyncio
import logging
from contextlib import suppress
from datetime import UTC, datetime
from typing import Any

import httpx

from .cron_configure import (
    CRON_CONFIG_INSTRUCTIONS,
    build_cron_config_prompt,
    parse_cron_config,
)
from .db import DB
from .events import TASKS_CLOSE, TASKS_OPEN, extract_terminal_text, parse_spawned_tasks
from .hermes import HermesClient
from .spawn import apply_spawned_tasks
from .prepare import CONNECTION_SLUGS
from .push import Pusher, PushPayload
from .schedule import advance_next_run, compute_next_run

log = logging.getLogger(__name__)

_CRON_INSTRUCTIONS = (
    "You are running a scheduled automation for the user. This is a fresh "
    "session with no prior conversation history. Complete the task described "
    "in the prompt end-to-end using Composio tools when needed. Do not ask "
    "clarifying questions — the prompt must be self-contained.\n\n"
    "SPAWNING TASKS. When the job discovers multiple independent actions "
    "(inbox scans, digests, recurring email checks), create separate todos "
    "for the user by ending your reply with one "
    f"{TASKS_OPEN} ... {TASKS_CLOSE} block containing JSON:\n"
    "{\n"
    "  \"tasks\": [\n"
    "    {\n"
    "      \"title\": \"Short task title\",\n"
    "      \"detail\": \"Optional longer context\",\n"
    "      \"summary\": \"Optional one-line prep hint\",\n"
    "      \"source_key\": \"stable dedupe id (e.g. gmail:message:ID)\",\n"
    "      \"connection_slug\": \"gmail\"\n"
    "    }\n"
    "  ]\n"
    "}\n"
    "Every task needs title and source_key. Reuse the same source_key for "
    "the same email/thread on later runs so duplicates are skipped. Use "
    "connection_slug when a specific Composio app is required.\n\n"
    "When finished, end with a one-line summary of what you did (outside "
    "the tasks block)."
)


async def configure_one_cron_job(
    cfg: Any,
    db: DB,
    pusher: Pusher,
    job: dict,
) -> None:
    """Refine a cron job's prompt/schedule; ask clarifying questions if needed."""
    job_id = job["id"]
    user_id = job["user_id"]
    name = job.get("name") or "Scheduled task"
    prompt = job.get("prompt") or ""
    schedule = job.get("schedule") or ""
    schedule_display = job.get("schedule_display")
    original_prompt = job.get("original_prompt")

    resume = db.get_latest_responded_cron_interaction(job_id)
    prior: dict | None = None
    if resume is not None:
        payload = resume.get("payload") or {}
        if payload.get("phase") == "configure":
            db.mark_cron_interaction(resume["id"], status="superseded")
            prior = {
                "prompt": resume.get("prompt") or "",
                "payload": payload,
                "response": resume.get("response") or {},
            }
            opt_id = str((resume.get("response") or {}).get("option_id") or "").lower()
            if opt_id == "cancel":
                db.update_cron_job(job_id, {"state": "paused", "enabled": False})
                db.supersede_open_cron_interactions(job_id)
                return

    pending = db.get_unconsumed_cron_messages(job_id)
    pending_bodies = [m.get("body") or "" for m in pending]
    pending_ids = [str(m["id"]) for m in pending]

    endpoint = db.get_user_hermes(user_id)
    if endpoint is None:
        db.update_cron_job(
            job_id,
            {"state": "scheduled", "enabled": True},
        )
        return

    config_prompt = build_cron_config_prompt(
        name=name,
        prompt=prompt,
        schedule=schedule,
        schedule_display=schedule_display,
        original_prompt=original_prompt,
        allowed_slugs=CONNECTION_SLUGS,
        prior=prior,
        pending_messages=pending_bodies or None,
    )

    hermes = HermesClient(endpoint)
    run_id: str | None = None
    final_text: str | None = None
    try:
        run_id = await hermes.start_run(
            config_prompt,
            session_id=f"cron-config:{job_id}",
            instructions=CRON_CONFIG_INSTRUCTIONS,
        )
        final_text = await asyncio.wait_for(
            _collect_final_text(hermes, run_id),
            timeout=min(cfg.run_timeout_secs, 120.0),
        )
    except (asyncio.TimeoutError, httpx.HTTPError, Exception) as e:
        log.warning("cron configure failed for job %s: %s", job_id, e)
    finally:
        with suppress(Exception):
            if run_id is not None:
                await hermes.stop_run(run_id)
        await hermes.aclose()

    if pending_ids:
        db.mark_cron_messages_consumed(pending_ids)

    fresh = db.get_cron_job(job_id)
    if fresh is None or fresh.get("state") != "configuring":
        return

    result = parse_cron_config(final_text or "", CONNECTION_SLUGS)
    if result is None:
        log.info("cron config produced no result for %s; enabling as-is", job_id)
        nxt = compute_next_run(schedule)
        db.update_cron_job(
            job_id,
            {
                "state": "scheduled",
                "enabled": True,
                "next_run_at": (nxt or datetime.now(UTC)).isoformat(),
            },
        )
        return

    updates: dict[str, Any] = {}
    if result.name:
        updates["name"] = result.name
    if result.prompt:
        updates["prompt"] = result.prompt
    if result.schedule:
        updates["schedule"] = result.schedule
    if result.schedule_display:
        updates["schedule_display"] = result.schedule_display
    if result.connection_slug:
        updates["connection_slug"] = result.connection_slug
    if result.summary:
        updates["configuration_summary"] = result.summary

    if result.needs_clarification:
        updates["state"] = "needs_input"
        db.update_cron_job(job_id, updates)

        payload: dict[str, Any] = {
            "phase": "configure",
            "allow_freeform": result.clarification_allow_freeform,
        }
        if result.summary:
            payload["summary"] = result.summary
        if result.clarification_options:
            payload["options"] = result.clarification_options
        if result.clarification_placeholder:
            payload["freeform_placeholder"] = result.clarification_placeholder

        db.supersede_open_cron_interactions(job_id)
        db.insert_cron_interaction(
            cron_job_id=job_id,
            user_id=user_id,
            kind="question",
            prompt=result.clarification_prompt or "I need a bit more info.",
            payload=payload,
            hermes_run_id=run_id,
        )
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Scheduled task needs input",
                body=(result.clarification_prompt or "")[:160],
                todo_id="",
                kind="cron_needs_input",
            ),
        )
        return

    effective_schedule = result.schedule or schedule
    nxt = compute_next_run(effective_schedule)
    updates["state"] = "scheduled"
    updates["enabled"] = True
    updates["next_run_at"] = (nxt or datetime.now(UTC)).isoformat()
    db.update_cron_job(job_id, updates)
    log.info("cron job %s configured and scheduled", job_id)


async def run_due_cron_jobs(
    cfg: Any,
    db: DB,
    pusher: Pusher,
) -> int:
    """Claim and execute all due cron jobs. Returns count executed."""
    due = db.claim_due_cron_jobs(limit=3)
    if not due:
        return 0
    ran = 0
    for job in due:
        try:
            await _run_one_cron_job(cfg, db, pusher, job)
            ran += 1
        except Exception:
            log.exception("cron job crashed for %s", job.get("id"))
    return ran


async def _run_one_cron_job(
    cfg: Any,
    db: DB,
    pusher: Pusher,
    job: dict,
) -> None:
    job_id = job["id"]
    user_id = job["user_id"]
    prompt = job.get("prompt") or job.get("name") or ""

    endpoint = db.get_user_hermes(user_id)
    if endpoint is None:
        db.update_cron_job(
            job_id,
            {
                "state": "scheduled",
                "last_status": "error: no hermes profile",
            },
        )
        return

    hermes = HermesClient(endpoint)
    run_id: str | None = None
    status = "ok"
    final = ""
    try:
        run_id = await hermes.start_run(
            f"Scheduled task:\n{prompt}",
            session_id=f"cron:{job_id}",
            instructions=_CRON_INSTRUCTIONS,
        )
        final = await asyncio.wait_for(
            _collect_final_text(hermes, run_id),
            timeout=min(cfg.run_timeout_secs, 300.0),
        )
        if not (final or "").strip():
            status = "empty"
    except (asyncio.TimeoutError, httpx.HTTPError, Exception) as e:
        log.warning("cron run failed for job %s: %s", job_id, e)
        status = f"error: {e}"
    finally:
        with suppress(Exception):
            if run_id is not None:
                await hermes.stop_run(run_id)
        await hermes.aclose()

    spawned_count = 0
    if status == "ok" and final.strip():
        spawned = parse_spawned_tasks(final)
        if spawned:
            spawned_count = apply_spawned_tasks(
                db,
                user_id,
                spawned,
                source_cron_job_id=job_id,
            )

    now = datetime.now(UTC)
    schedule = job.get("schedule") or ""
    nxt = advance_next_run(schedule, after=now)
    updates: dict[str, Any] = {
        "last_run_at": now.isoformat(),
        "last_status": status[:200],
    }
    if nxt is None:
        updates["state"] = "completed"
        updates["enabled"] = False
        updates["next_run_at"] = None
    else:
        updates["state"] = "scheduled"
        updates["next_run_at"] = nxt.isoformat()

    db.update_cron_job(job_id, updates)

    if spawned_count > 0:
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="New tasks ready",
                body=f"{spawned_count} task(s) from {(job.get('name') or 'automation')[:80]}",
                todo_id="",
                kind="tasks_spawned",
            ),
        )
    elif status.startswith("error"):
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Scheduled task failed",
                body=(job.get("name") or "Automation")[:160],
                todo_id="",
                kind="cron_failed",
            ),
        )


async def _collect_final_text(hermes: HermesClient, run_id: str) -> str:
    final: str | None = None
    async for ev in hermes.stream_events(run_id):
        text = extract_terminal_text(ev.event, ev.data)
        if text is not None:
            final = text
            break
    return final or ""
