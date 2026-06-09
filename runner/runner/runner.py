"""Main poll loop: claim requested todos, drive Hermes, stream steps + push."""
from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from .config import Config, load
from .db import AgentModelSetting, DB
from .activity import AgentActivityService, ActivitySnapshot
from .events import (
    ArtifactRequest,
    TTSCall,
    TTSResult,
    Translated,
    extract_terminal_text,
    extract_usage_total,
    merge_terminal_translated,
    translate,
)
from .hermes import HermesClient
from .hermes_memory import (
    HermesMemoryStore,
    MemoryTarget,
    fingerprint as memory_fingerprint,
)
from .memory_extraction import (
    MEMORY_EXTRACT_INSTRUCTIONS,
    build_memory_extraction_prompt,
    parse_memory_extraction,
)
from .memory_sync import (
    mirror_hermes_memory_to_supabase,
    sync_active_memories_to_hermes,
)
from .model_settings import AgentModelApplier
from .prepare import (
    CONNECTION_SLUGS,
    PREP_INSTRUCTIONS,
    augment_cron_from_text,
    build_prepare_prompt,
    parse_prepare,
)
from .prompt import (
    build_followup_prompt as _build_followup_prompt,
    build_prompt as _build_prompt,
    build_resume_prompt as _build_resume_prompt,
    prep_session_id_for_todo as _prep_session_id_for_todo,
    session_id_for_todo as _session_id_for_todo,
    session_key_for_user as _session_key_for_user,
)
from .push import Pusher, PushPayload
from .spawn import apply_spawned_tasks
from .cron import configure_one_cron_job, run_due_cron_jobs
from .schedule import compute_next_run

log = logging.getLogger(__name__)


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def _resolve_attachment_urls(db: DB, todo_id: str) -> list[str]:
    """Look up attachments for a todo and return a list of fresh signed URLs.

    Failures are non-fatal: a single missing signed URL means we drop that
    one entry, but we never block execution because of attachment plumbing.
    """
    rows = db.list_todo_attachments(todo_id)
    urls: list[str] = []
    for row in rows:
        path = row.get("storage_path")
        if not path:
            continue
        url = db.sign_attachment_url(path)
        if url:
            urls.append(url)
    return urls


def _model_setting_label(setting: AgentModelSetting | None) -> str:
    if setting is None:
        return "profile-default"
    status = f" status={setting.apply_status}" if setting.apply_status else ""
    return f"{setting.provider}/{setting.model}{status}"


async def run_one_todo(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    todo: dict,
) -> None:
    todo_id = todo["id"]
    user_id = todo["user_id"]
    title = todo["title"]
    detail = todo.get("detail") or ""
    original_title = todo.get("original_title") or ""
    preparation_summary = todo.get("preparation_summary") or ""
    connection_slug = todo.get("connection_slug") or ""

    # Sign attachment URLs fresh every iteration so resumes that cross the
    # TTL still get URLs the agent can fetch. ``vision_analyze`` only ever
    # sees these once they're embedded in the prompt below.
    attachment_urls = _resolve_attachment_urls(db, todo_id)

    # If the user just answered an interaction the agent posted earlier, treat
    # this re-claim as a resume: short-circuit "cancel" responses, otherwise
    # weave the user's reply into the prompt so the next Hermes run can act on
    # it directly. The interaction row stays "responded" so the activity log
    # still shows what the user picked.
    resume = db.get_latest_responded_interaction(todo_id)
    # Preparation-phase interactions are consumed by prepare_one_todo and must
    # not leak into the execution prompt (they're a different conversation).
    if resume is not None and (resume.get("payload") or {}).get("phase") == "prepare":
        resume = None

    # Free-form chat messages the user typed in the detail view composer.
    # These are stamped consumed_at below once they actually make it into
    # a prompt so the next resume doesn't replay them.
    pending_messages = db.get_unconsumed_user_messages(todo_id)
    pending_bodies = [m.get("body") or "" for m in pending_messages]
    pending_ids = [str(m["id"]) for m in pending_messages]

    # Short-circuit a "cancel" response before any prompt work — nothing else
    # needs to happen and we don't want to spin up the Hermes endpoint just to
    # tear it down.
    if resume is not None:
        response = resume.get("response") or {}
        option_id = str(response.get("option_id") or "").lower()
        db.mark_interaction(resume["id"], status="superseded")
        if option_id == "cancel":
            log.info("todo %s cancelled via interaction response", todo_id)
            db.update_todo(todo_id, {"status": "cancelled"})
            db.supersede_open_interactions(todo_id)
            db.insert_step(
                todo_id=todo_id,
                user_id=user_id,
                kind="error",
                text="Cancelled by user.",
            )
            if pending_ids:
                db.mark_user_messages_consumed(pending_ids)
            return

    log.info("processing todo %s user=%s title=%r", todo_id, user_id, title)

    endpoint = db.get_user_hermes(user_id)
    if endpoint is None:
        db.update_todo(
            todo_id,
            {
                "status": "failed",
                "error_message": "No Hermes profile is provisioned for this user.",
            },
        )
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="error",
            text="No Hermes profile provisioned. Ask the admin to add you.",
        )
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Couldn't start your task",
                body="Your account isn't set up yet.",
                todo_id=todo_id,
                kind="failed",
            ),
        )
        return

    model_setting = db.get_agent_model_setting(user_id)
    try:
        setting = db.get_pending_agent_model_setting(user_id)
        if setting is not None:
            log.info(
                "applying model setting user=%s profile=%s model=%s endpoint=%s:%s",
                user_id,
                endpoint.profile_name,
                _model_setting_label(setting),
                endpoint.host,
                endpoint.port,
            )
            AgentModelApplier(cfg).apply(endpoint.profile_name, setting)
            db.update_agent_model_status(user_id, status="applied")
            model_setting = AgentModelSetting(
                provider=setting.provider,
                model=setting.model,
                apply_status="applied",
            )
        log.info(
            "Hermes model context user=%s profile=%s model=%s endpoint=%s:%s",
            user_id,
            endpoint.profile_name,
            _model_setting_label(model_setting),
            endpoint.host,
            endpoint.port,
        )
    except Exception as e:
        log.exception(
            "failed to apply model setting user=%s profile=%s model=%s endpoint=%s:%s",
            user_id,
            endpoint.profile_name,
            _model_setting_label(model_setting),
            endpoint.host,
            endpoint.port,
        )
        db.update_agent_model_status(user_id, status="failed", error=str(e))
        db.update_todo(
            todo_id,
            {
                "status": "failed",
                "error_message": "Couldn't apply your selected model settings.",
            },
        )
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="error",
            text=f"Couldn't apply your selected model settings: {e}",
        )
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Model setup failed",
                body="Open Settings > Model to choose another supported model.",
                todo_id=todo_id,
                kind="failed",
            ),
        )
        return

    # Stage any newly-pinned user memories into Hermes' USER.md / MEMORY.md
    # BEFORE we build the prompt or start the run, for two reasons:
    #   1. Hermes freezes the memory snapshot at session start. With per-todo
    #      session ids this run already gets a fresh snapshot, but we still
    #      want the pin on disk before the snapshot is taken.
    #   2. We pass the staged rows into the prompt builder so the agent gets
    #      a nudge to curate them via its own ``memory`` tool (dedupe,
    #      replace older entries) rather than treating them as opaque text.
    memory_store = HermesMemoryStore(cfg.hermes_profiles_dir, endpoint.profile_name)
    staged_memories = sync_active_memories_to_hermes(db, memory_store, user_id)
    task_context = (
        _task_context_for_prompt(db, todo_id)
        if resume is not None or pending_bodies
        else None
    )

    if resume is not None:
        prompt = _build_resume_prompt(
            title=title,
            detail=detail,
            interaction=resume,
            original_title=original_title,
            preparation_summary=preparation_summary,
            connection_slug=connection_slug,
            attachment_urls=attachment_urls,
            pinned_memories=staged_memories,
            task_context=task_context,
        )
        if pending_bodies:
            quoted = "\n".join(
                f"  > {line}"
                for body in pending_bodies
                for line in (body.strip().splitlines() or [""])
                if body.strip()
            )
            if quoted:
                prompt = (
                    f"{prompt}\n\n"
                    "The user also sent these follow-up messages:\n"
                    f"{quoted}"
                )
            db.mark_user_messages_consumed(pending_ids)
    elif pending_bodies:
        prompt = _build_followup_prompt(
            title,
            detail,
            messages=pending_bodies,
            original_title=original_title,
            preparation_summary=preparation_summary,
            connection_slug=connection_slug,
            attachment_urls=attachment_urls,
            pinned_memories=staged_memories,
            task_context=task_context,
        )
        db.mark_user_messages_consumed(pending_ids)
    else:
        prompt = _build_prompt(
            title,
            detail,
            original_title=original_title,
            preparation_summary=preparation_summary,
            connection_slug=connection_slug,
            attachment_urls=attachment_urls,
            pinned_memories=staged_memories,
        )

    hermes = HermesClient(endpoint)
    cancel_watcher: asyncio.Task | None = None
    run_id: str | None = None
    # Per-todo session so MEMORY.md/USER.md are reloaded fresh; cross-todo
    # recall still works via session_search (FTS5 over state.db). The
    # X-Hermes-Session-Key header keeps an eventual external memory
    # provider scoped per-user even though we're rotating session_id.
    session_id = _session_id_for_todo(user_id, todo_id)
    session_key = _session_key_for_user(user_id)
    terminal_status: str | None = None

    try:
        run_id = await hermes.start_run(
            prompt,
            session_id=session_id,
            session_key=session_key,
        )
        db.update_todo(
            todo_id,
            {"hermes_run_id": run_id, "hermes_session_id": session_id},
        )
        log.info(
            "todo %s started run %s on session %s profile=%s model=%s",
            todo_id,
            run_id,
            session_id,
            endpoint.profile_name,
            _model_setting_label(model_setting),
        )

        cancel_event = asyncio.Event()
        cancel_watcher = asyncio.create_task(
            _watch_for_cancel(cfg, db, todo_id, cancel_event)
        )

        consume_task = asyncio.create_task(
            _consume_run(
                cfg,
                db,
                pusher,
                hermes,
                todo,
                run_id,
                profile_name=endpoint.profile_name,
            )
        )

        done, pending = await asyncio.wait(
            {consume_task, asyncio.create_task(cancel_event.wait())},
            timeout=cfg.run_timeout_secs,
            return_when=asyncio.FIRST_COMPLETED,
        )
        for t in pending:
            t.cancel()

        if cancel_event.is_set():
            log.info("todo %s cancelled by user", todo_id)
            with suppress(Exception):
                await hermes.stop_run(run_id)
            terminal_status = "cancelled"
            db.update_todo(todo_id, {"status": "cancelled"})
            db.supersede_open_interactions(todo_id)
            db.insert_step(
                todo_id=todo_id,
                user_id=user_id,
                kind="error",
                text="Cancelled by user.",
            )
            _write_activity(
                db,
                todo_id=todo_id,
                user_id=user_id,
                snapshot=AgentActivityService().mark_terminal(
                    state="failed",
                    phase="cancelled",
                    title="Cancelled",
                ),
                hermes_run_id=run_id,
            )
        elif consume_task in done:
            terminal_status = consume_task.result()
        else:
            log.warning("todo %s timed out after %ss", todo_id, cfg.run_timeout_secs)
            with suppress(Exception):
                await hermes.stop_run(run_id)
            terminal_status = "failed"
            db.update_todo(
                todo_id,
                {"status": "failed", "error_message": "Timed out."},
            )
            db.insert_step(
                todo_id=todo_id,
                user_id=user_id,
                kind="error",
                text="The agent took too long and was stopped.",
            )
            _write_activity(
                db,
                todo_id=todo_id,
                user_id=user_id,
                snapshot=AgentActivityService().mark_terminal(
                    state="failed",
                    phase="failed",
                    title="Timed out",
                    detail="The agent took too long and was stopped.",
                ),
                hermes_run_id=run_id,
            )

    except httpx.HTTPError as e:
        log.exception(
            "hermes call failed for todo %s profile=%s endpoint=%s:%s model=%s",
            todo_id,
            endpoint.profile_name,
            endpoint.host,
            endpoint.port,
            _model_setting_label(model_setting),
        )
        terminal_status = "failed"
        db.update_todo(
            todo_id,
            {"status": "failed", "error_message": f"Hermes error: {e}"},
        )
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="error",
            text=f"Couldn't reach the agent: {e}",
        )
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=AgentActivityService().mark_terminal(
                state="failed",
                phase="failed",
                title="Couldn't reach the agent",
                detail=str(e),
            ),
            hermes_run_id=run_id,
        )
    except Exception as e:
        log.exception("unexpected failure processing todo %s", todo_id)
        terminal_status = "failed"
        db.update_todo(
            todo_id,
            {"status": "failed", "error_message": str(e)},
        )
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=AgentActivityService().mark_terminal(
                state="failed",
                phase="failed",
                title="Unexpected error",
                detail=str(e),
            ),
            hermes_run_id=run_id,
        )
    finally:
        if cancel_watcher:
            cancel_watcher.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await cancel_watcher
        await hermes.aclose()
        # Mirror anything Hermes wrote into MEMORY.md / USER.md during this
        # run back into Supabase so Settings > Memory reflects the latest
        # agent-curated state. Runs the same way whether the run succeeded,
        # failed, or hit an interaction pause — Hermes may have persisted new
        # facts before any of those transitions.
        with suppress(Exception):
            mirror_hermes_memory_to_supabase(db, memory_store, user_id)
        if terminal_status == "done":
            with suppress(Exception):
                await _extract_memories_after_todo(
                    db,
                    todo,
                    endpoint=endpoint,
                    memory_store=memory_store,
                )

    # Terminal push.
    if terminal_status == "done":
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Done",
                body=_short(title),
                todo_id=todo_id,
                kind="done",
            ),
        )
    elif terminal_status == "failed":
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Task failed",
                body=_short(title),
                todo_id=todo_id,
                kind="failed",
            ),
        )
    # needs_auth pushes are sent inline by _consume_run when the URL appears.
    # cancelled produces no push (the user did it themselves).


async def prepare_one_todo(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    todo: dict,
) -> None:
    """Run the lightweight preparation pass for a newly-created todo.

    Reads the user's raw input, asks Hermes (with a strict no-tools, JSON-only
    instruction) to rewrite the title, pick a likely connection slug, and
    decide whether one clarifying question is needed. On success the todo
    moves to ``status='requested'`` so the execution loop picks it up and
    starts working automatically (no second "Do it" tap). On a clarification
    it moves to ``status='needs_input'`` with a prep-phase interaction. On a
    recurring automation it converts to a ``cron_jobs`` row.

    Failure modes are intentionally non-fatal: if Hermes is unreachable, the
    prep JSON is missing/malformed, or we time out, we still queue the todo
    for execution from the user's original wording. Preparation is best-effort
    UX polish, not a gate on execution.
    """
    todo_id = todo["id"]
    user_id = todo["user_id"]
    raw_title = todo["title"]
    detail = todo.get("detail") or ""

    log.info("preparing todo %s user=%s title=%r", todo_id, user_id, raw_title)

    # Preserve the user's original wording the first time we touch this row.
    if not todo.get("original_title"):
        db.update_todo(todo_id, {"original_title": raw_title})

    # Surface the preparation pass in the live activity feed so the iOS
    # card shows something better than "Preparing task..." while we wait
    # for Hermes to rewrite the title.
    _write_activity(
        db,
        todo_id=todo_id,
        user_id=user_id,
        snapshot=AgentActivityService().initial(
            phase="preparing",
            title="Reading your request",
        ),
        hermes_run_id=None,
    )

    # If we already asked a clarifying question and the user answered it,
    # weave the response into this prep pass so the model can finalize.
    resume = db.get_latest_responded_interaction(todo_id)
    prior: dict | None = None
    if resume is not None:
        payload = resume.get("payload") or {}
        if payload.get("phase") == "prepare":
            db.mark_interaction(resume["id"], status="superseded")
            prior = {
                "prompt": resume.get("prompt") or "",
                "payload": payload,
                "response": resume.get("response") or {},
            }
            # Honor a "cancel" answer the same way execution does.
            opt_id = str((resume.get("response") or {}).get("option_id") or "").lower()
            if opt_id == "cancel":
                db.update_todo(todo_id, {"status": "cancelled"})
                db.supersede_open_interactions(todo_id)
                db.insert_step(
                    todo_id=todo_id,
                    user_id=user_id,
                    kind="error",
                    text="Cancelled by user.",
                )
                return

    endpoint = db.get_user_hermes(user_id)
    if endpoint is None:
        # No Hermes for this user yet: skip prep and queue the row for
        # execution anyway so the existing "no profile" error surfaces on the
        # task card without the user having to tap Do it first.
        db.update_todo(todo_id, {"status": "requested"})
        return

    model_setting = db.get_agent_model_setting(user_id)
    log.info(
        "preparing with Hermes model context todo=%s user=%s profile=%s model=%s endpoint=%s:%s",
        todo_id,
        user_id,
        endpoint.profile_name,
        _model_setting_label(model_setting),
        endpoint.host,
        endpoint.port,
    )

    memory_store = HermesMemoryStore(cfg.hermes_profiles_dir, endpoint.profile_name)
    with suppress(Exception):
        sync_active_memories_to_hermes(db, memory_store, user_id)

    prep_prompt = build_prepare_prompt(
        title=raw_title,
        detail=detail,
        allowed_slugs=CONNECTION_SLUGS,
        prior=prior,
        attachment_urls=_resolve_attachment_urls(db, todo_id),
        organization_examples=db.get_todo_organization_examples(
            user_id,
            exclude_todo_id=todo_id,
        ),
    )
    # Per-todo prep session so any USER.md edits we just staged are visible
    # in the prep snapshot, and so prep turns from different todos do not
    # share a transcript. Memory/session_search remain per-profile.
    session_id = _prep_session_id_for_todo(todo_id)
    session_key = _session_key_for_user(user_id)

    hermes = HermesClient(endpoint)
    run_id: str | None = None
    final_text: str | None = None
    try:
        run_id = await hermes.start_run(
            prep_prompt,
            session_id=session_id,
            session_key=session_key,
            instructions=PREP_INSTRUCTIONS,
        )
        final_text = await asyncio.wait_for(
            _collect_final_text(hermes, run_id),
            timeout=min(cfg.run_timeout_secs, 120.0),
        )
    except (asyncio.TimeoutError, httpx.HTTPError, Exception) as e:
        log.warning("prep run failed for todo %s: %s", todo_id, e)
    finally:
        with suppress(Exception):
            if run_id is not None:
                await hermes.stop_run(run_id)
        await hermes.aclose()

    # The user can cancel a long-running prep from the card. Bail out if the
    # row is no longer "preparing" so a late prep result doesn't clobber a
    # cancellation (or a manual "Do it" the user issued in the meantime).
    fresh = db.get_todo(todo_id)
    if fresh is None or fresh.get("status") != "preparing":
        log.info(
            "prep finished for %s but status moved to %s; skipping write",
            todo_id,
            (fresh or {}).get("status"),
        )
        return

    result = parse_prepare(final_text or "", CONNECTION_SLUGS)
    if result is None:
        # Couldn't get usable prep — queue the row anyway so the agent can
        # still work from the user's original wording instead of stranding
        # the task on the list.
        log.info("prep produced no result for todo %s; auto-queuing for execution", todo_id)
        db.update_todo(todo_id, {"status": "requested"})
        return

    # Safety net: if the user asked for recurrence but the model returned
    # kind=task (or cron without a schedule), infer from the raw input.
    combined_input = f"{raw_title}\n{detail}".strip()
    result = augment_cron_from_text(result, combined_input)
    log.info(
        "prep result todo=%s kind=%s schedule=%r ready=%s",
        todo_id,
        result.kind,
        result.schedule,
        result.ready,
    )

    updates: dict[str, Any] = {}
    if result.title:
        updates["title"] = result.title
    if result.connection_slug:
        updates["connection_slug"] = result.connection_slug
    if result.topic:
        updates["topic"] = result.topic
    if result.collection_name:
        updates["collection_name"] = result.collection_name
    if result.summary:
        updates["preparation_summary"] = result.summary

    if result.needs_clarification:
        # Persist the prep fields we do have, flip to needs_input, and open
        # one interaction with phase='prepare' so the resume routes back to
        # this preparation flow (not into execution).
        updates["status"] = "needs_input"
        db.update_todo(todo_id, updates)
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=AgentActivityService().mark_terminal(
                state="paused",
                phase="needs_input",
                title="Needs your input",
                detail=result.clarification_prompt,
            ),
            hermes_run_id=run_id,
        )

        payload: dict[str, Any] = {
            "phase": "prepare",
            "allow_freeform": result.clarification_allow_freeform,
        }
        if result.summary:
            payload["summary"] = result.summary
        if result.clarification_options:
            payload["options"] = result.clarification_options
        if result.clarification_placeholder:
            payload["freeform_placeholder"] = result.clarification_placeholder

        db.supersede_open_interactions(todo_id)
        db.insert_interaction(
            todo_id=todo_id,
            user_id=user_id,
            kind="question",
            prompt=result.clarification_prompt or "I need a bit more info.",
            payload=payload,
            hermes_run_id=run_id,
        )
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Needs your input",
                body=(result.clarification_prompt or "")[:160],
                todo_id=todo_id,
                kind="needs_input",
            ),
        )
        return

    # Recurring automation — convert to a cron job and remove the placeholder todo.
    if result.is_cron and result.schedule:
        from datetime import UTC, datetime

        # Pin the new cron job to the timezone the user was in when they
        # typed the schedule. This keeps "9 AM daily" anchored to that
        # location for the lifetime of the job, even if the user later
        # travels. ``None`` falls through to legacy UTC evaluation.
        client_timezone = todo.get("client_timezone") or None
        nxt = compute_next_run(result.schedule, timezone=client_timezone)
        name = result.title or raw_title
        prompt_text = detail.strip() or raw_title
        if result.summary and result.summary not in prompt_text:
            prompt_text = f"{prompt_text}\n\n{result.summary}".strip()

        job_fields: dict[str, Any] = {
            "user_id": user_id,
            "name": name[:200],
            "prompt": prompt_text[:4000],
            "original_prompt": raw_title[:4000],
            "schedule": result.schedule,
            "schedule_display": result.schedule_display,
            "connection_slug": result.connection_slug,
            "state": "configuring",
            "enabled": False,
            "next_run_at": (nxt or datetime.now(UTC)).isoformat(),
            "timezone": client_timezone,
        }
        inserted = db.insert_cron_job(job_fields)
        if inserted:
            log.info(
                "prep converted todo %s to cron job %s schedule=%r",
                todo_id,
                inserted.get("id"),
                result.schedule,
            )
            db.delete_todo(todo_id)
            await configure_one_cron_job(cfg, db, pusher, inserted)
        else:
            log.error(
                "cron insert failed for todo %s — is migration "
                "20240601000011_cron_jobs applied? Leaving as task.",
                todo_id,
            )
            updates["status"] = "todo"
            db.update_todo(todo_id, updates)
        return

    # Ready — auto-queue for execution so the user does not have to tap
    # "Do it" a second time. The execution loop will claim the row, flip
    # it to `running`, and start streaming Hermes events as usual.
    updates["status"] = "requested"
    db.update_todo(todo_id, updates)
    _write_activity(
        db,
        todo_id=todo_id,
        user_id=user_id,
        snapshot=AgentActivityService().initial(
            phase="starting",
            title="Starting task",
        ),
        hermes_run_id=run_id,
    )

    # Multi-task split: insert extras as already-prepared todos that also
    # auto-run. Keeps the UX consistent — every row created from the
    # `+` sheet starts working without an extra tap.
    for extra in result.additional_tasks:
        db.insert_prepared_todo(
            user_id=user_id,
            title=extra.title,
            original_title=extra.title,
            detail=None,
            connection_slug=extra.connection_slug,
            topic=extra.topic,
            collection_name=extra.collection_name,
            preparation_summary=extra.summary,
            status="requested",
        )


async def _collect_final_text(hermes: HermesClient, run_id: str) -> str:
    """Drain an SSE stream and return the assistant's final reply text.

    Used by ``prepare_one_todo``: we don't care about per-tool events for
    the preparation pass, only the structured JSON block in the final reply.
    """
    final: str | None = None
    async for ev in hermes.stream_events(run_id):
        text = extract_terminal_text(ev.event, ev.data)
        if text is not None:
            final = text
            break
    return final or ""


def _write_activity(
    db: DB,
    *,
    todo_id: str,
    user_id: str,
    snapshot: ActivitySnapshot | None,
    hermes_run_id: str | None,
) -> None:
    """Persist one activity snapshot through the runner DB wrapper.

    Wrapped in its own helper so the runner only depends on the
    snapshot shape (not Supabase column names) and so future call
    sites (preparation pass, cancellation paths, timeouts) all push
    through the same code.
    """
    if snapshot is None:
        return
    db.upsert_agent_activity(
        todo_id=todo_id,
        user_id=user_id,
        fields=snapshot.to_db_fields(hermes_run_id=hermes_run_id),
    )


async def _consume_run(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    hermes: HermesClient,
    todo: dict,
    run_id: str,
    *,
    profile_name: str | None = None,
) -> str:
    """Consume the SSE stream and return the terminal status."""
    todo_id = todo["id"]
    user_id = todo["user_id"]
    terminal: str | None = None
    # Sum of per-turn usage we've already pushed to `todos.total_tokens`
    # for THIS run. Used to compute a delta against the authoritative
    # run total when the SSE stream ends.
    live_total: int = 0
    # Pending text_to_speech calls keyed by `call_id` so we can pair the
    # spoken text (captured on the `function_call` event) with the
    # generated file path (captured on the matching
    # `function_call_output`). Older entries are kept until the run ends —
    # the dict is small and per-run.
    pending_tts: dict[str, TTSCall] = {}
    pending_tts_started_at: dict[str, float] = {}
    lifecycle_tts_uploaded = False
    # Hermes can emit more than one terminal assistant message per run
    # (e.g. a short artifact line plus a longer summary). We drain the
    # stream and persist one merged ``final`` row for the chat transcript.
    pending_final: Translated | None = None

    # Drives the iOS "what is Hermes doing right now?" surfaces: the
    # todo card status line, the detail-view animated cards, and the
    # Live Activity widget. `todo_steps` keeps the historic audit log.
    activity = AgentActivityService()
    latest_activity: ActivitySnapshot | None = None
    heartbeat_task: asyncio.Task | None = None

    async def activity_heartbeat() -> None:
        while True:
            await asyncio.sleep(25)
            _write_activity(
                db,
                todo_id=todo_id,
                user_id=user_id,
                snapshot=activity.heartbeat(latest_activity),
                hermes_run_id=run_id,
            )

    _write_activity(
        db,
        todo_id=todo_id,
        user_id=user_id,
        snapshot=activity.initial(phase="starting", title="Starting agent…"),
        hermes_run_id=run_id,
    )
    heartbeat_task = asyncio.create_task(activity_heartbeat())

    try:
        async for ev in hermes.stream_events(run_id):
            effect = translate(ev.event, ev.data)
            if effect is None:
                continue
            defer_final = (
                effect.step_kind == "final" and effect.new_status == "done"
            )
            if effect.step_kind and not defer_final:
                db.insert_step(
                    todo_id=todo_id,
                    user_id=user_id,
                    kind=effect.step_kind,
                    text=effect.text,
                    url=effect.url,
                    tool_name=effect.tool_name,
                )
            # Update the live activity snapshot for every event the translator
            # recognized. Terminal events also write a closing snapshot below
            # so the UI doesn't sit on stale "Working on..." copy.
            snap = activity.observe(effect, event_name=ev.event, raw_data=ev.data)
            if snap is not None:
                latest_activity = snap
                _write_activity(
                    db,
                    todo_id=todo_id,
                    user_id=user_id,
                    snapshot=snap,
                    hermes_run_id=run_id,
                )
            # Persist artifacts before any terminal `break` below so a `done`
            # event that also carries deliverables still lands them in the DB.
            artifact_text = _first_text_artifact_body(effect.artifacts) or effect.text
            for artifact in effect.artifacts:
                if await _maybe_persist_audio_link_artifact(
                    db,
                    todo_id=todo_id,
                    user_id=user_id,
                    run_id=run_id,
                    artifact=artifact,
                    fallback_text=artifact_text,
                ):
                    continue
                if await _maybe_persist_image_artifact(
                    db,
                    todo_id=todo_id,
                    user_id=user_id,
                    run_id=run_id,
                    artifact=artifact,
                ):
                    continue
                db.upsert_artifact(
                    todo_id=todo_id,
                    user_id=user_id,
                    key=artifact.key,
                    kind=artifact.kind,
                    title=artifact.title,
                    payload=artifact.payload,
                    hermes_run_id=run_id,
                )
            if effect.tts_call is not None:
                pending_tts[effect.tts_call.call_id] = effect.tts_call
                pending_tts_started_at[effect.tts_call.call_id] = time.time() - 10
            if effect.tts_result is not None:
                _persist_tts_audio(
                    db,
                    todo_id=todo_id,
                    user_id=user_id,
                    run_id=run_id,
                    result=effect.tts_result,
                    call=pending_tts.get(effect.tts_result.call_id),
                )
                lifecycle_tts_uploaded = True
            if (
                effect.step_kind == "tool_result"
                and effect.tool_name == "text_to_speech"
                and not lifecycle_tts_uploaded
            ):
                call = pending_tts.get("hermes-lifecycle")
                started_at = pending_tts_started_at.get("hermes-lifecycle", time.time() - 60)
                file_path = _find_latest_hermes_tts_audio(
                    cfg,
                    profile_name=profile_name,
                    since=started_at,
                )
                if file_path:
                    _persist_tts_audio(
                        db,
                        todo_id=todo_id,
                        user_id=user_id,
                        run_id=run_id,
                        result=TTSResult(
                            call_id="hermes-lifecycle",
                            file_path=str(file_path),
                            provider="elevenlabs",
                        ),
                        call=call,
                    )
                    lifecycle_tts_uploaded = True
                else:
                    log.warning(
                        "text_to_speech completed but no local audio file found "
                        "todo=%s run=%s profile=%s since=%.3f",
                        todo_id, run_id, profile_name, started_at,
                    )
            if effect.spawned_tasks and effect.new_status == "done":
                spawned_count = apply_spawned_tasks(
                    db,
                    user_id,
                    effect.spawned_tasks,
                    source_todo_id=todo_id,
                )
                if spawned_count > 0:
                    await pusher.send(
                        db.list_apns_tokens(user_id),
                        PushPayload(
                            title="New tasks ready",
                            body=f"{spawned_count} task(s) from your agent run",
                            todo_id=todo_id,
                            kind="tasks_spawned",
                        ),
                    )
            # Mid-stream `response.completed` events carry per-turn usage; we
            # increment as they arrive so the iOS pill counter ticks upward
            # while the agent is still working. We deliberately skip events
            # that also carry `new_status` because those terminal events tend
            # to repeat the run-cumulative total — we let the post-stream
            # backfill (`get_run`) reconcile those instead of double-counting.
            if effect.usage_total > 0 and effect.new_status is None:
                db.increment_todo_tokens(todo_id, effect.usage_total)
                live_total += effect.usage_total
            if effect.new_status:
                fields: dict = {"status": effect.new_status}
                if effect.new_status == "done":
                    fields["completed_at"] = "now()"
                elif effect.new_status == "failed":
                    fields["error_message"] = effect.text or "Agent reported a failure."
                # Supabase REST can't take SQL like "now()" — drop it and let the
                # trigger keep updated_at fresh; we don't strictly need completed_at
                # to be wall-clock-accurate for the prototype.
                fields.pop("completed_at", None)
                db.update_todo(todo_id, fields)

                if effect.new_status == "needs_auth" and effect.url:
                    await pusher.send(
                        db.list_apns_tokens(user_id),
                        PushPayload(
                            title="Connect an account",
                            body="Tap to authorize so the agent can finish.",
                            todo_id=todo_id,
                            kind="oauth_needed",
                        ),
                    )
                    _write_activity(
                        db,
                        todo_id=todo_id,
                        user_id=user_id,
                        snapshot=activity.mark_terminal(
                            state="paused",
                            phase="needs_auth",
                            title="Connect an account to continue",
                            detail=effect.text,
                        ),
                        hermes_run_id=run_id,
                    )
                    # The run usually pauses here in practice; we stop consuming
                    # so the next "Do it" can resume cleanly with fresh creds.
                    await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)
                    return "needs_auth"

                if effect.new_status == "needs_input" and effect.interaction is not None:
                    # Replace any previously-open interaction so the UI only ever
                    # shows one actionable card at a time.
                    db.supersede_open_interactions(todo_id)
                    db.insert_interaction(
                        todo_id=todo_id,
                        user_id=user_id,
                        kind=effect.interaction.kind,
                        prompt=effect.interaction.prompt,
                        payload=effect.interaction.payload,
                        hermes_run_id=run_id,
                    )
                    await pusher.send(
                        db.list_apns_tokens(user_id),
                        PushPayload(
                            title="Needs your input",
                            body=effect.interaction.prompt[:160],
                            todo_id=todo_id,
                            kind="needs_input",
                        ),
                    )
                    _write_activity(
                        db,
                        todo_id=todo_id,
                        user_id=user_id,
                        snapshot=activity.mark_terminal(
                            state="paused",
                            phase="needs_input",
                            title="Needs your input",
                            detail=effect.interaction.prompt,
                        ),
                        hermes_run_id=run_id,
                    )
                    await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)
                    return "needs_input"

                if effect.new_status in ("done", "failed"):
                    terminal = effect.new_status
                    if effect.new_status == "done" and effect.step_kind == "final":
                        pending_final = merge_terminal_translated(
                            pending_final, effect
                        )
                    elif effect.new_status == "failed":
                        _write_activity(
                            db,
                            todo_id=todo_id,
                            user_id=user_id,
                            snapshot=activity.mark_terminal(
                                state="failed",
                                phase="failed",
                                title="Failed",
                                detail=effect.text,
                            ),
                            hermes_run_id=run_id,
                        )
                        break
                    # Keep draining so a later ``run.completed`` / duplicate
                    # ``response.completed`` can be merged into one chat reply.
                    continue
    finally:
        if heartbeat_task is not None:
            heartbeat_task.cancel()
            with suppress(asyncio.CancelledError):
                await heartbeat_task

    if pending_final is not None:
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="final",
            text=pending_final.text,
        )
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=activity.mark_terminal(
                state="completed",
                phase="done",
                title="Done",
                detail=pending_final.text,
            ),
            hermes_run_id=run_id,
        )
    elif terminal == "done":
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="final",
            text="Done.",
        )
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=activity.mark_terminal(
                state="completed",
                phase="done",
                title="Done",
                detail="Done.",
            ),
            hermes_run_id=run_id,
        )
    if terminal is None:
        # If the stream ends without an explicit terminal event, treat the
        # run as successful rather than leaving the todo stuck in running.
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="final",
            text="Done.",
        )
        db.update_todo(todo_id, {"status": "done"})
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=activity.mark_terminal(
                state="completed",
                phase="done",
                title="Done",
                detail="Done.",
            ),
            hermes_run_id=run_id,
        )
        terminal = "done"
    if terminal in ("done", "failed"):
        db.supersede_open_interactions(todo_id)
        await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)
    return terminal

_AUDIO_MIME_BY_EXT: dict[str, str] = {
    ".mp3": "audio/mpeg",
    ".ogg": "audio/ogg",
    ".oga": "audio/ogg",
    ".opus": "audio/ogg",
    ".wav": "audio/wav",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
    ".flac": "audio/flac",
}


_AUDIO_LINK_HINTS = ("audio", "spoken", "speech", "recording", "voice")


_IMAGE_MIME_BY_EXT: dict[str, str] = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".heic": "image/heic",
    ".heif": "image/heif",
}


_IMAGE_EXT_BY_MIME: dict[str, str] = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/svg+xml": ".svg",
    "image/heic": ".heic",
    "image/heif": ".heif",
}


def _candidate_hermes_audio_dirs(
    cfg: Config,
    *,
    profile_name: str | None,
) -> list[Path]:
    """Likely Hermes TTS output dirs for profile-scoped API runs."""
    home = Path.home()
    dirs: list[Path] = []
    if profile_name:
        dirs.append(home / ".hermes" / "profiles" / profile_name / "audio_cache")
        dirs.append(Path(cfg.hermes_profiles_dir) / profile_name / "audio_cache")
    dirs.append(home / ".hermes" / "audio_cache")
    dirs.append(home / ".hermes" / "cache" / "audio" / "audio_cache")

    seen: set[str] = set()
    out: list[Path] = []
    for d in dirs:
        key = str(d)
        if key in seen:
            continue
        seen.add(key)
        out.append(d)
    return out


def _find_latest_hermes_tts_audio(
    cfg: Config,
    *,
    profile_name: str | None,
    since: float,
) -> Path | None:
    """Find the newest Hermes-generated audio file after ``since``.

    The Hermes Runs API lifecycle event shape for ``tool.completed`` does
    not include the ``file_path`` that the lower-level TTS tool returns.
    The tool still writes to the profile audio cache, so the runner
    recovers the file by modification time and uploads it to Supabase.
    """
    candidates: list[Path] = []
    for directory in _candidate_hermes_audio_dirs(cfg, profile_name=profile_name):
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in _AUDIO_MIME_BY_EXT:
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime >= since and stat.st_size > 0:
                candidates.append(path)
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def _first_text_artifact_body(artifacts: list[ArtifactRequest]) -> str | None:
    """Return the first text artifact body from one final reply, if present."""
    for artifact in artifacts:
        if artifact.kind != "text":
            continue
        text = artifact.payload.get("text")
        if isinstance(text, str) and text.strip():
            return text.strip()
    return None


def _looks_like_audio_link_artifact(artifact: ArtifactRequest) -> bool:
    """Heuristic for model-emitted audio links we should promote in-app.

    The ideal path is Hermes' native ``text_to_speech`` tool, whose local
    file path we capture separately. In practice the agent may instead
    create a Composio/R2 "Audio recording" link. Those links open in a
    browser and expire, so the runner downloads them, re-uploads to our
    private bucket, and skips the original link row.
    """
    if artifact.kind != "link":
        return False
    title = (artifact.title or "").lower()
    key = artifact.key.lower()
    if not any(hint in title or hint in key for hint in _AUDIO_LINK_HINTS):
        return False
    payload = artifact.payload or {}
    url = payload.get("url")
    if not isinstance(url, str) or not url.startswith(("http://", "https://")):
        return False
    provider = str(payload.get("provider") or "").lower()
    # Be conservative: only promote obvious audio links or links created by
    # Composio's file/audio flow. Generic "audio docs" links should remain
    # normal link artifacts unless their title/key says they are recordings.
    return provider == "composio" or "recording" in title or "audio" in key


def _extension_for_audio_response(url: str, content_type: str | None) -> str:
    """Pick a storage extension from HTTP content-type or URL suffix."""
    ctype = (content_type or "").split(";", 1)[0].strip().lower()
    by_type = {
        "audio/mpeg": ".mp3",
        "audio/mp3": ".mp3",
        "audio/ogg": ".ogg",
        "audio/opus": ".ogg",
        "audio/wav": ".wav",
        "audio/x-wav": ".wav",
        "audio/mp4": ".m4a",
        "audio/aac": ".aac",
        "audio/flac": ".flac",
    }
    if ctype in by_type:
        return by_type[ctype]
    path = httpx.URL(url).path.lower()
    ext = os.path.splitext(path)[1]
    if ext in _AUDIO_MIME_BY_EXT:
        return ext
    return ".mp3"


async def _maybe_persist_audio_link_artifact(
    db: DB,
    *,
    todo_id: str,
    user_id: str,
    run_id: str,
    artifact: ArtifactRequest,
    fallback_text: str | None,
) -> bool:
    """Convert an expiring audio link artifact into a native audio artifact.

    Returns True when the artifact was recognized as an audio link and
    should not be persisted as a browser-opening ``link`` card. If the
    download/upload fails we still return True: keeping the bad link is the
    exact UX this fallback is meant to avoid.
    """
    if not _looks_like_audio_link_artifact(artifact):
        return False
    url = str((artifact.payload or {}).get("url") or "")
    try:
        async with httpx.AsyncClient(
            follow_redirects=True,
            timeout=httpx.Timeout(connect=10.0, read=60.0, write=10.0, pool=10.0),
        ) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            audio_bytes = resp.content
    except Exception as e:
        log.warning(
            "audio link download failed todo=%s run=%s url=%s: %s",
            todo_id, run_id, url[:160], e,
        )
        return True
    if not audio_bytes:
        log.warning("audio link empty todo=%s run=%s url=%s", todo_id, run_id, url[:160])
        return True
    ext = _extension_for_audio_response(url, resp.headers.get("content-type"))
    mime = _AUDIO_MIME_BY_EXT.get(ext, "application/octet-stream")
    storage_path = db.upload_todo_audio(
        user_id=user_id,
        todo_id=todo_id,
        filename=f"{uuid.uuid4().hex}{ext}",
        data=audio_bytes,
        mime_type=mime,
    )
    if not storage_path:
        return True
    payload: dict[str, Any] = {
        "bucket": "todo-audio",
        "storage_path": storage_path,
        "mime_type": mime,
        "provider": str((artifact.payload or {}).get("provider") or "remote"),
        "byte_size": len(audio_bytes),
    }
    if fallback_text and fallback_text.strip():
        payload["text"] = fallback_text.strip()
    db.upsert_artifact(
        todo_id=todo_id,
        user_id=user_id,
        key="audio",
        kind="audio",
        title=artifact.title or "Spoken summary",
        payload=payload,
        hermes_run_id=run_id,
    )
    return True


def _persist_tts_audio(
    db: DB,
    *,
    todo_id: str,
    user_id: str,
    run_id: str,
    result: TTSResult,
    call: TTSCall | None,
) -> None:
    """Upload one TTS-generated file and upsert the matching audio artifact.

    Best-effort: a missing source file, an unreadable file, an upload
    failure, or any other transient error logs a warning and returns
    without raising. We never want a TTS hiccup to fail an otherwise
    successful task — the chat-visible final reply is still authoritative.

    Audio is keyed on the literal string ``"audio"`` so a second TTS call
    in the same run replaces the prior card via the existing upsert on
    ``(todo_id, artifact_key)``. That matches the single-player UX in
    the iOS detail header.
    """
    expanded = os.path.expanduser(os.path.expandvars(result.file_path))
    if not os.path.isfile(expanded):
        log.warning(
            "tts audio file missing for todo=%s run=%s path=%s",
            todo_id, run_id, expanded,
        )
        return
    try:
        with open(expanded, "rb") as f:
            audio_bytes = f.read()
    except Exception as e:
        log.error(
            "tts audio read failed for todo=%s run=%s path=%s: %s",
            todo_id, run_id, expanded, e,
        )
        return
    if not audio_bytes:
        log.warning(
            "tts audio empty for todo=%s run=%s path=%s",
            todo_id, run_id, expanded,
        )
        return
    ext = os.path.splitext(expanded)[1].lower() or ".mp3"
    mime = _AUDIO_MIME_BY_EXT.get(ext, "application/octet-stream")
    filename = f"{uuid.uuid4().hex}{ext}"
    storage_path = db.upload_todo_audio(
        user_id=user_id,
        todo_id=todo_id,
        filename=filename,
        data=audio_bytes,
        mime_type=mime,
    )
    if not storage_path:
        return
    payload: dict[str, Any] = {
        "bucket": "todo-audio",
        "storage_path": storage_path,
        "mime_type": mime,
        "voice_compatible": result.voice_compatible,
        "byte_size": len(audio_bytes),
    }
    if result.provider:
        payload["provider"] = result.provider
    spoken_text = (call.text if call is not None else "").strip()
    if spoken_text:
        payload["text"] = spoken_text
    if call is not None and call.voice:
        payload["voice"] = call.voice
    db.upsert_artifact(
        todo_id=todo_id,
        user_id=user_id,
        key="audio",
        kind="audio",
        title="Spoken summary",
        payload=payload,
        hermes_run_id=run_id,
    )


def _extension_for_image_response(url: str, content_type: str | None) -> str:
    """Pick a storage extension from HTTP content-type or URL suffix."""
    ctype = (content_type or "").split(";", 1)[0].strip().lower()
    if ctype in _IMAGE_EXT_BY_MIME:
        return _IMAGE_EXT_BY_MIME[ctype]
    path = httpx.URL(url).path.lower()
    ext = os.path.splitext(path)[1]
    if ext in _IMAGE_MIME_BY_EXT:
        return ext
    return ".png"


async def _maybe_persist_image_artifact(
    db: DB,
    *,
    todo_id: str,
    user_id: str,
    run_id: str,
    artifact: ArtifactRequest,
) -> bool:
    """Persist an ``image`` artifact by uploading its bytes to Supabase Storage.

    The agent emits ``[[DOIT_ARTIFACT]]`` blocks of ``type: "image"`` that
    carry one of:

      * ``payload.url`` — http(s) URL to download (Figma render URLs,
        Composio file URLs, generated-image URLs from a model). The URL
        usually expires, so we re-host it in our private bucket.
      * ``payload.file_path`` — local path on the runner host (for image
        tools that drop bytes into a cache dir, like Hermes built-ins).
      * ``payload.bucket`` + ``payload.storage_path`` — already-hosted
        in our bucket; pass through unchanged so the agent can emit the
        same artifact twice without re-uploading.

    Returns True when the artifact was recognized as an image; the caller
    must skip the generic ``upsert_artifact`` path. We always claim the
    artifact (return True) once we recognize it, even on download/upload
    failure, to avoid persisting a half-formed image row the iOS card
    would skip anyway.
    """
    if artifact.kind != "image":
        return False
    payload = dict(artifact.payload or {})
    bucket = str(payload.get("bucket") or "").strip()
    storage_path = str(payload.get("storage_path") or "").strip()
    if bucket == "todo-images" and storage_path:
        # Already hosted in the right place — just persist as-is.
        db.upsert_artifact(
            todo_id=todo_id,
            user_id=user_id,
            key=artifact.key,
            kind="image",
            title=artifact.title,
            payload=payload,
            hermes_run_id=run_id,
        )
        return True

    image_bytes: bytes | None = None
    mime: str | None = None
    ext: str | None = None
    source_url: str | None = None

    file_path = payload.get("file_path") or payload.get("path")
    if isinstance(file_path, str) and file_path.strip():
        expanded = os.path.expanduser(os.path.expandvars(file_path.strip()))
        if os.path.isfile(expanded):
            try:
                with open(expanded, "rb") as f:
                    image_bytes = f.read()
                ext = os.path.splitext(expanded)[1].lower() or ".png"
                mime = _IMAGE_MIME_BY_EXT.get(ext, "application/octet-stream")
            except Exception as e:
                log.error(
                    "image read failed todo=%s run=%s path=%s: %s",
                    todo_id, run_id, expanded, e,
                )
        else:
            log.warning(
                "image artifact file missing todo=%s run=%s path=%s",
                todo_id, run_id, expanded,
            )

    if image_bytes is None:
        url_raw = payload.get("url") or payload.get("source_url")
        if isinstance(url_raw, str) and url_raw.startswith(("http://", "https://")):
            source_url = url_raw
            try:
                async with httpx.AsyncClient(
                    follow_redirects=True,
                    timeout=httpx.Timeout(connect=10.0, read=60.0, write=10.0, pool=10.0),
                ) as client:
                    resp = await client.get(url_raw)
                    resp.raise_for_status()
                    image_bytes = resp.content
                ext = _extension_for_image_response(
                    url_raw, resp.headers.get("content-type")
                )
                mime = _IMAGE_MIME_BY_EXT.get(ext, "application/octet-stream")
            except Exception as e:
                log.warning(
                    "image download failed todo=%s run=%s url=%s: %s",
                    todo_id, run_id, url_raw[:160], e,
                )

    if not image_bytes or not ext or not mime:
        log.warning(
            "image artifact dropped todo=%s run=%s key=%s (no bytes)",
            todo_id, run_id, artifact.key,
        )
        return True

    storage_path = db.upload_todo_image(
        user_id=user_id,
        todo_id=todo_id,
        filename=f"{uuid.uuid4().hex}{ext}",
        data=image_bytes,
        mime_type=mime,
    )
    if not storage_path:
        return True

    new_payload: dict[str, Any] = {
        "bucket": "todo-images",
        "storage_path": storage_path,
        "mime_type": mime,
        "byte_size": len(image_bytes),
    }
    # Carry through descriptive metadata the agent included so the iOS
    # card can show provider/prompt/dimensions without a follow-up call.
    for key in ("provider", "prompt", "width", "height", "alt_text", "description"):
        if key in payload and payload[key] not in (None, ""):
            new_payload[key] = payload[key]
    if source_url:
        new_payload["source_url"] = source_url

    db.upsert_artifact(
        todo_id=todo_id,
        user_id=user_id,
        key=artifact.key,
        kind="image",
        title=artifact.title,
        payload=new_payload,
        hermes_run_id=run_id,
    )
    return True


async def _reconcile_run_tokens(
    db: DB,
    hermes: HermesClient,
    todo_id: str,
    run_id: str,
    live_total: int,
) -> None:
    """Top up `todos.total_tokens` with whatever we missed from the SSE stream.

    Hermes' `GET /v1/runs/{id}` returns `usage.total_tokens` for the whole
    run on terminal state. If that authoritative number is higher than the
    sum we accumulated from per-turn `response.completed` events, the
    difference gets added so the lifetime counter stays accurate.
    """
    try:
        snapshot = await hermes.get_run(run_id)
    except Exception as e:
        log.warning("get_run %s for token reconcile failed: %s", run_id, e)
        return
    authoritative = extract_usage_total(snapshot.get("usage"))
    if authoritative <= live_total:
        return
    delta = authoritative - live_total
    log.info(
        "reconcile tokens todo=%s run=%s live=%d auth=%d delta=%d",
        todo_id, run_id, live_total, authoritative, delta,
    )
    db.increment_todo_tokens(todo_id, delta)


async def _watch_for_cancel(
    cfg: Config,
    db: DB,
    todo_id: str,
    cancel_event: asyncio.Event,
) -> None:
    """Set `cancel_event` if the user flips the todo to status='cancelled'."""
    while not cancel_event.is_set():
        await asyncio.sleep(max(cfg.poll_interval_secs, 1.0))
        row = db.get_todo(todo_id)
        if row is None:
            cancel_event.set()
            return
        if row.get("status") == "cancelled":
            cancel_event.set()
            return


def _short(s: str, limit: int = 80) -> str:
    return s if len(s) <= limit else s[: limit - 1] + "\u2026"


async def _extract_memories_after_todo(
    db: DB,
    todo: dict,
    *,
    endpoint,
    memory_store: HermesMemoryStore,
) -> None:
    """Run Doit's post-task memory extraction pass for a completed todo."""
    todo_id = str(todo["id"])
    user_id = str(todo["user_id"])
    settings = db.get_memory_settings(user_id)
    if settings.get("automatic_suggestions_enabled") is False:
        return
    active_memories = db.list_active_memories_for_sync(user_id)
    prompt = build_memory_extraction_prompt(
        todo=todo,
        task_context=_task_context_for_prompt(db, todo_id),
        existing_memories=active_memories,
        custom_instructions=settings.get("custom_instructions"),
    )

    hermes = HermesClient(endpoint)
    run_id: str | None = None
    try:
        run_id = await hermes.start_run(
            prompt,
            session_id=f"doit-memory-extract-{todo_id}",
            session_key=_session_key_for_user(user_id),
            instructions=MEMORY_EXTRACT_INSTRUCTIONS,
        )
        final_text = await asyncio.wait_for(
            _collect_memory_extraction_text(hermes, run_id),
            timeout=90.0,
        )
    finally:
        with suppress(Exception):
            if run_id is not None:
                await hermes.stop_run(run_id)
        await hermes.aclose()

    candidates = parse_memory_extraction(final_text or "")
    if not candidates:
        return
    for candidate in candidates:
        memory_status = "active" if candidate.should_auto_activate else "proposed"
        db.upsert_extracted_memory(
            user_id=user_id,
            target=candidate.target,
            title=candidate.title,
            body=candidate.body,
            confidence=candidate.confidence,
            reason=candidate.reason,
            source_todo_id=todo_id,
            memory_status=memory_status,
        )
    sync_active_memories_to_hermes(db, memory_store, user_id)


async def _collect_memory_extraction_text(hermes: HermesClient, run_id: str) -> str:
    final: str | None = None
    async for ev in hermes.stream_events(run_id):
        text = extract_terminal_text(ev.event, ev.data)
        if text is not None:
            final = text
            break
    return final or ""


def _sync_pending_memories_to_hermes(
    db: DB,
    store: HermesMemoryStore,
    user_id: str,
) -> list[dict]:
    """Write the user's pinned memories into Hermes' USER.md / MEMORY.md.

    User-authored rows in Supabase carry ``source='user'`` and start at
    ``sync_status='pending'``. We group them by target, stage them into the
    matching file (preserving everything already there), then update each
    row to ``synced`` with the fingerprint of the text we wrote so the
    reverse-direction mirror (Hermes -> Supabase) won't duplicate them.

    Returns the rows that actually landed on disk this call (i.e. the ones
    we marked ``synced``). The runner forwards them to the prompt so the
    agent can curate them with its own ``memory`` tool on the same turn.
    """
    pending = db.list_memories_for_sync(user_id)
    if not pending:
        return []

    by_target: dict[MemoryTarget, list[dict]] = {"user": [], "memory": []}
    for row in pending:
        target = row.get("target") or "user"
        if target not in by_target:
            target = "user"
        by_target[target].append(row)

    staged: list[dict] = []
    now = datetime.now(UTC).isoformat()
    for target, rows in by_target.items():
        if not rows:
            continue
        texts = [_memory_row_to_entry_text(row) for row in rows]
        try:
            _, skipped = store.stage_pinned_entries(target, texts)
        except Exception as e:
            log.exception("memory sync to %s failed for user %s", target, user_id)
            for row in rows:
                db.mark_memory_sync_failed(row["id"], error=str(e))
            continue

        skipped_set = {memory_fingerprint(text) for text in skipped}
        for row in rows:
            text = _memory_row_to_entry_text(row)
            fp = memory_fingerprint(text)
            if fp in skipped_set:
                db.mark_memory_sync_failed(
                    row["id"],
                    error=(
                        "Hermes memory is full; remove or shorten existing "
                        "entries before adding this one."
                    ),
                )
            else:
                db.mark_memory_synced(row["id"], fingerprint=fp, when_iso=now)
                staged.append(row)
    return staged


def _mirror_hermes_memory_to_supabase(
    db: DB,
    store: HermesMemoryStore,
    user_id: str,
) -> None:
    """Reflect what's currently in Hermes' memory files back into Supabase.

    Adds agent-curated entries the user hasn't seen, and removes
    ``source='hermes'`` rows whose fingerprints no longer exist on disk
    (i.e. Hermes deleted or consolidated them). User-authored rows are never
    deleted here — pinned facts survive even after the agent rewrites the
    file.
    """
    now = datetime.now(UTC).isoformat()
    existing = db.list_synced_memories(user_id)
    existing_by_key: dict[tuple[str, str], dict] = {}
    for row in existing:
        fp = row.get("hermes_fingerprint")
        target = row.get("target")
        if not fp or target not in ("user", "memory"):
            continue
        existing_by_key[(target, fp)] = row

    seen_keys: set[tuple[str, str]] = set()
    for target in ("user", "memory"):
        try:
            entries = store.read_entries(target)  # type: ignore[arg-type]
        except Exception as e:
            log.warning(
                "read hermes %s memory for user %s failed: %s",
                target,
                user_id,
                e,
            )
            continue
        for entry in entries:
            key = (target, entry.fingerprint)
            seen_keys.add(key)
            if key in existing_by_key:
                continue
            db.upsert_hermes_memory(
                user_id=user_id,
                target=target,
                text=entry.text,
                fingerprint=entry.fingerprint,
                when_iso=now,
            )

    for key, row in existing_by_key.items():
        if key in seen_keys:
            continue
        if row.get("source") != "hermes":
            continue
        db.delete_memory(row["id"])


def _memory_row_to_entry_text(row: dict) -> str:
    """Turn a Supabase ``memories`` row into a Hermes-style entry string."""
    title = (row.get("title") or "").strip()
    body = (row.get("body") or "").strip()
    if title and body and title != body:
        return f"{title}: {body}"
    return body or title


def _task_context_for_prompt(db: DB, todo_id: str) -> dict[str, list[dict]]:
    """Explicit same-task context for follow-up prompts.

    We still reuse the same per-todo Hermes session id for each run, but the
    task detail's DB rows are the reliable source of what the user can see:
    artifact cards, chat messages, and visible activity. Including a compact
    snapshot in follow-up prompts keeps the agent grounded when the user says
    "that doc" or "the first sheet" after a completed run.
    """
    return {
        "artifacts": db.list_todo_artifacts_for_context(todo_id),
        "messages": db.list_todo_messages_for_context(todo_id),
        "steps": db.list_todo_steps_for_context(todo_id),
    }


async def main_loop() -> None:
    setup_logging()
    cfg = load()
    db = DB(cfg)
    pusher = Pusher(cfg)
    log.info("doit runner online; polling every %ss", cfg.poll_interval_secs)

    while True:
        # Preparation is short and user-facing (the card spinner sits there
        # until we finish), so it gets first dibs each tick. Execution work
        # only runs once the prep queue is drained.
        try:
            prep_todo = db.claim_next_preparing_todo()
        except Exception:
            log.exception("prep claim failed; will retry")
            prep_todo = None

        if prep_todo is not None:
            try:
                await prepare_one_todo(cfg, db, pusher, prep_todo)
            except Exception:
                log.exception("prepare_one_todo crashed for %s", prep_todo.get("id"))
            continue

        try:
            cfg_job = db.claim_next_configuring_cron_job()
        except Exception:
            log.exception("cron configure claim failed")
            cfg_job = None

        if cfg_job is not None:
            try:
                await configure_one_cron_job(cfg, db, pusher, cfg_job)
            except Exception:
                log.exception("configure_one_cron_job crashed for %s", cfg_job.get("id"))
            continue

        try:
            cron_ran = await run_due_cron_jobs(cfg, db, pusher)
        except Exception:
            log.exception("cron tick failed")
            cron_ran = 0
        if cron_ran:
            continue

        try:
            todo = db.claim_next_requested_todo()
        except Exception:
            log.exception("claim failed; will retry")
            todo = None

        if todo is None:
            await asyncio.sleep(cfg.poll_interval_secs)
            continue

        try:
            await run_one_todo(cfg, db, pusher, todo)
        except Exception:
            log.exception("run_one_todo crashed for %s", todo.get("id"))


def main() -> None:
    asyncio.run(main_loop())


if __name__ == "__main__":
    main()
