"""Main poll loop: claim requested todos, drive Hermes, stream steps + push."""
from __future__ import annotations

import asyncio
import logging
import os
import re
import time
import uuid
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from .artifact_guard import RunUrlTracker, maybe_upsert_artifact
from .browse_skill import maybe_prefetch_browse_skill
from .config import Config, load
from .db import AgentModelSetting, DB
from .activity import (
    AgentActivityService,
    ActivitySnapshot,
    execution_start_snapshot,
    prep_queue_snapshot,
)
from .events import (
    ArtifactRequest,
    TTSCall,
    TTSResult,
    Translated,
    build_blocked_send_approval_payload,
    extract_terminal_text,
    extract_usage_total,
    find_placeholder_matches,
    is_outbound_send_tool,
    merge_terminal_translated,
    outbound_send_approved_from_resume,
    parse_artifacts,
    parse_interaction,
    translate,
)
from .hermes import HermesClient
from .hermes_memory import (
    HermesMemoryStore,
    MemoryTarget,
    fingerprint as memory_fingerprint,
    memory_store_for_profile,
)
from .memory_consolidate import consolidate_if_near_cap
from .memory_extraction import (
    MEMORY_EXTRACT_INSTRUCTIONS,
    build_memory_extraction_prompt,
    parse_memory_extraction,
    storage_status_for_extracted_memory,
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
    demote_unrequested_cron,
    parse_prepare,
    prep_fast_path,
    prep_fast_path_enabled,
)
from .prompt import (
    build_followup_prompt as _build_followup_prompt,
    build_prompt as _build_prompt,
    build_resume_prompt as _build_resume_prompt,
    concurrent_isolation_nudge,
    prep_session_id_for_todo as _prep_session_id_for_todo,
    session_id_for_todo as _session_id_for_todo,
    session_key_for_user as _session_key_for_user,
    user_wants_spoken_audio,
)
from .provision import run_provisioning
from .push import Pusher, PushPayload
from .scheduler import TaskPool, UserGate, UserGates
from .spawn import apply_spawned_tasks
from .cron import configure_one_cron_job, run_one_cron_job
from .schedule import compute_next_run

log = logging.getLogger(__name__)


def _hermes_http_failure_message(error: httpx.HTTPError) -> tuple[str, str]:
    """Return (user-facing todo error, step/activity detail) for Hermes failures."""
    if isinstance(error, httpx.HTTPStatusError):
        status = error.response.status_code
        if status == 401:
            message = (
                "Agent gateway authentication failed. Ask an admin to repair your "
                "Hermes profile and retry this task."
            )
            detail = (
                "The agent gateway rejected the runner credentials. Re-run "
                "provisioning for this user or restart the profile after syncing "
                "API_SERVER_KEY."
            )
            return message, detail
        if status == 403:
            message = (
                "Agent gateway authorization failed. Ask an admin to check this "
                "Hermes profile and retry this task."
            )
            detail = "The agent gateway rejected the runner request with HTTP 403."
            return message, detail
        if 500 <= status:
            message = "Agent gateway is unavailable. Please retry this task in a moment."
            detail = f"The agent gateway returned HTTP {status}."
            return message, detail
        message = "Agent gateway rejected the task request. Please retry this task."
        detail = f"The agent gateway returned HTTP {status}."
        return message, detail

    if isinstance(error, (httpx.ConnectError, httpx.ConnectTimeout)):
        message = "Agent gateway is not reachable. Please retry this task in a moment."
        detail = "The runner could not connect to the local Hermes gateway."
        return message, detail

    if isinstance(error, httpx.TimeoutException):
        message = "Agent gateway timed out. Please retry this task in a moment."
        detail = "The runner timed out while talking to the Hermes gateway."
        return message, detail

    return "Agent gateway failed to start this task.", str(error)


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


def _parse_ts(value: str | None) -> datetime | None:
    """Best-effort ISO timestamp parse for Supabase row timestamps."""
    if not value:
        return None
    text = str(value).strip().replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _memory_store(cfg: Config, profile_name: str) -> HermesMemoryStore:
    return memory_store_for_profile(
        cfg.hermes_profiles_dir,
        profile_name,
        user_char_limit=cfg.hermes_user_char_limit,
        memory_char_limit=cfg.hermes_memory_char_limit,
    )


def _consolidate_memory_if_near_cap(store: HermesMemoryStore, user_id: str) -> None:
    for target in ("user", "memory"):
        with suppress(Exception):
            consolidate_if_near_cap(store, target, user_id=user_id)


def _resolve_attachment_urls_split(
    db: DB,
    todo_id: str,
) -> tuple[list[str], list[str]]:
    """Signed attachment URLs split into (previously processed, new).

    The boundary is the most recent terminal step (final/error) for the
    todo: rows attached before it were visible to a completed run; rows
    attached after it are new since the last run. On first runs (no
    terminal step) everything lands in "new" and the prompt renders the
    flat Attachments block, byte-identical to today.

    Signed URLs are regenerated each run, so the split is the only way the
    model can tell a re-signed old receipt from a freshly attached one.
    """
    cutoff = _parse_ts(db.get_last_terminal_step_ts(todo_id))
    processed: list[str] = []
    new: list[str] = []
    for row in db.list_todo_attachments(todo_id):
        path = row.get("storage_path")
        if not path:
            continue
        url = db.sign_attachment_url(path)
        if not url:
            continue
        created = _parse_ts(row.get("created_at"))
        if cutoff is not None and created is not None and created <= cutoff:
            processed.append(url)
        else:
            new.append(url)
    return processed, new


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
    *,
    gate: UserGate | None = None,
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
    # sees these once they're embedded in the prompt below. Split into
    # previously-processed vs newly-attached so follow-up prompts can label
    # them; on first runs everything is "new" and the block stays flat.
    processed_attachment_urls, attachment_urls = _resolve_attachment_urls_split(
        db, todo_id
    )

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

    # Did the USER ask for spoken audio anywhere in this task's text? This
    # guards every audio persistence path in _consume_run: agent-generated
    # audio for a task that never asked for it is discarded instead of
    # surfacing as an unsolicited voice memo.
    resume_freeform = ""
    if resume is not None:
        resume_freeform = str((resume.get("response") or {}).get("text") or "")
    audio_requested = user_wants_spoken_audio(
        original_title, title, detail, resume_freeform, *pending_bodies
    )

    # Short-circuit a "cancel" response before any prompt work — nothing else
    # needs to happen and we don't want to spin up the Hermes endpoint just to
    # tear it down.
    outbound_send_approved = outbound_send_approved_from_resume(resume)
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
    _write_activity(
        db,
        todo_id=todo_id,
        user_id=user_id,
        snapshot=execution_start_snapshot(
            todo,
            pending_messages=pending_bodies or None,
            resumed_from_interaction=resume is not None,
        ),
        hermes_run_id=None,
    )

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

    # Per-user critical sections: the runner rewrites this profile's memory
    # files, config.yaml/.env, and skills dir around runs. Overlapping runs
    # for the same user serialize those windows through the gate's staging
    # lock; the long SSE-consumption middle stays unlocked.
    staging_lock = gate.staging if gate is not None else asyncio.Lock()

    model_setting = db.get_agent_model_setting(user_id)
    try:
        setting = db.get_pending_agent_model_setting(user_id)
        if setting is not None and gate is not None and not gate.restart_safe:
            # Applying a model setting restarts the user's Hermes gateway,
            # which would kill their other in-flight runs. Leave the setting
            # pending — a later run with no concurrent siblings applies it.
            log.info(
                "deferring model apply user=%s profile=%s model=%s: "
                "%d other run(s) in flight",
                user_id,
                endpoint.profile_name,
                _model_setting_label(setting),
                gate.active_total - 1,
            )
            setting = None
        if setting is not None:
            log.info(
                "applying model setting user=%s profile=%s model=%s endpoint=%s:%s",
                user_id,
                endpoint.profile_name,
                _model_setting_label(setting),
                endpoint.host,
                endpoint.port,
            )
            async with staging_lock:
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
    memory_store = _memory_store(cfg, endpoint.profile_name)
    async with staging_lock:
        staged_memories = sync_active_memories_to_hermes(db, memory_store, user_id)
    # Image-only follow-up: the task already completed at least once
    # (processed attachments exist) and the user attached something new
    # without typing a message. Route it through the follow-up prompt so
    # the model gets the "something new arrived" framing + task history
    # instead of a bare first-run prompt.
    image_only_followup = bool(
        processed_attachment_urls and attachment_urls and not pending_bodies
    )
    task_context = (
        _task_context_for_prompt(db, todo_id)
        if resume is not None or pending_bodies or image_only_followup
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
            topic=todo.get("topic"),
            processed_attachment_urls=processed_attachment_urls,
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
    elif pending_bodies or image_only_followup:
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
            topic=todo.get("topic"),
            processed_attachment_urls=processed_attachment_urls,
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
            topic=todo.get("topic"),
            processed_attachment_urls=processed_attachment_urls,
        )

    if gate is not None and gate.active_exec > 1:
        prompt = f"{prompt}{concurrent_isolation_nudge()}"

    async with staging_lock:
        browse_skill = await maybe_prefetch_browse_skill(
            cfg,
            todo,
            endpoint.profile_name,
            allow_restart=(gate.restart_safe if gate is not None else True),
        )
    if browse_skill:
        skill_name = browse_skill.get("name") or "the installed browse.sh skill"
        skill_slug = browse_skill.get("slug") or "unknown slug"
        prompt = (
            "Browse.sh preflight found a likely site-specific skill for this task: "
            f"`{skill_name}` ({skill_slug}). Before saying a capability is unavailable, "
            f"use skills_list and skill_view for `{skill_name}`, then follow that skill's "
            "`browse ...` CLI workflow or Hermes browser tools. Do not use generic MCP "
            "tool search as a substitute for this installed browse.sh skill.\n\n"
            f"{prompt}"
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
                audio_requested=audio_requested,
                outbound_send_approved=outbound_send_approved,
                gate=gate,
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
        failure_message, failure_detail = _hermes_http_failure_message(e)
        log.exception(
            "hermes call failed for todo %s profile=%s endpoint=%s:%s model=%s user_message=%r",
            todo_id,
            endpoint.profile_name,
            endpoint.host,
            endpoint.port,
            _model_setting_label(model_setting),
            failure_message,
        )
        terminal_status = "failed"
        db.update_todo(
            todo_id,
            {"status": "failed", "error_message": failure_message},
        )
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="error",
            text=f"Couldn't reach the agent: {failure_detail}",
        )
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=AgentActivityService().mark_terminal(
                state="failed",
                phase="failed",
                title="Couldn't reach the agent",
                detail=failure_detail,
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
        async with staging_lock:
            with suppress(Exception):
                mirror_hermes_memory_to_supabase(db, memory_store, user_id)
                _consolidate_memory_if_near_cap(memory_store, user_id)
        if terminal_status == "done":
            with suppress(Exception):
                await _extract_memories_after_todo(
                    db,
                    todo,
                    endpoint=endpoint,
                    memory_store=memory_store,
                    staging_lock=staging_lock,
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


async def _convert_prep_todo_to_cron(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    todo: dict,
    *,
    name: str,
    prompt_text: str,
    schedule: str,
    schedule_display: str | None,
    connection_slug: str | None,
    gate: UserGate | None = None,
) -> bool:
    """Convert a prep-classified recurring todo into a ``cron_jobs`` row.

    Shared by the LLM prep path and the deterministic fast path. Pins the
    job to the timezone the user was in when they typed the schedule so
    "9 AM daily" stays anchored even if they travel. Returns ``True`` when
    the job was inserted (placeholder todo deleted, configure pass kicked
    off) and ``False`` when the insert failed and the caller should leave
    the row as a normal task.
    """
    from datetime import UTC, datetime

    todo_id = todo["id"]
    user_id = todo["user_id"]
    client_timezone = todo.get("client_timezone") or None
    nxt = compute_next_run(schedule, timezone=client_timezone)
    job_fields: dict[str, Any] = {
        "user_id": user_id,
        "name": name[:200],
        "prompt": prompt_text[:4000],
        "original_prompt": str(todo.get("title") or name)[:4000],
        "schedule": schedule,
        "schedule_display": schedule_display,
        "connection_slug": connection_slug,
        "state": "configuring",
        "enabled": False,
        "next_run_at": (nxt or datetime.now(UTC)).isoformat(),
        "timezone": client_timezone,
    }
    inserted = db.insert_cron_job(job_fields)
    if not inserted:
        log.error(
            "cron insert failed for todo %s — is migration "
            "20240601000011_cron_jobs applied? Leaving as task.",
            todo_id,
        )
        return False
    log.info(
        "prep converted todo %s to cron job %s schedule=%r",
        todo_id,
        inserted.get("id"),
        schedule,
    )
    db.delete_todo(todo_id)
    await configure_one_cron_job(cfg, db, pusher, inserted, gate=gate)
    return True


# Prep only stages Hermes memory when the user's words actually reference
# remembered context; for everything else the sync is startup tax (prep
# never recalls memories, only classifies).
_PREP_MEMORY_HINT = re.compile(
    r"\b(remember|memor(?:y|ies)|like\s+last\s+time|as\s+usual|my\s+usual|"
    r"preferences?|you\s+know)\b",
    re.IGNORECASE,
)

# Only sign attachment URLs during prep when the task text references the
# image; otherwise the count alone is passed (execution signs the real URLs).
_PREP_IMAGE_HINT = re.compile(
    r"\b(image|images|photo|photos|picture|pictures|screenshot|screenshots|"
    r"receipt|receipts|attach(?:ed|ment|ments)?)\b",
    re.IGNORECASE,
)


async def prepare_one_todo(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    todo: dict,
    *,
    gate: UserGate | None = None,
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

    combined_text = f"{raw_title}\n{detail}".strip()
    attachment_rows = db.list_todo_attachments(todo_id)

    # Deterministic fast path (1c, DOIT_PREP_FAST_PATH): skip the Hermes
    # prep run for the narrow obvious cases — trivial bare reminders and
    # unambiguous recurring directives. Anything with attachments or a
    # prior clarification always goes through LLM prep.
    if prep_fast_path_enabled() and prior is None and not attachment_rows:
        decision = prep_fast_path(combined_text)
        if decision is not None and decision.kind == "task":
            log.info("prep fast-path: queuing bare reminder todo=%s", todo_id)
            db.update_todo(todo_id, {"status": "requested"})
            _write_activity(
                db,
                todo_id=todo_id,
                user_id=user_id,
                snapshot=AgentActivityService().initial(
                    phase="starting",
                    title="Starting task",
                ),
                hermes_run_id=None,
            )
            return
        if decision is not None and decision.kind == "cron" and decision.schedule:
            log.info(
                "prep fast-path: converting todo=%s to cron schedule=%r",
                todo_id,
                decision.schedule,
            )
            converted = await _convert_prep_todo_to_cron(
                cfg,
                db,
                pusher,
                todo,
                name=raw_title,
                prompt_text=detail.strip() or raw_title,
                schedule=decision.schedule,
                schedule_display=decision.schedule_display,
                connection_slug=None,
                gate=gate,
            )
            if converted:
                return
            # Insert failed — fall through to normal LLM prep.

    endpoint = db.get_user_hermes(user_id)
    if endpoint is None:
        # No Hermes for this user yet: skip prep and queue the row for
        # execution anyway so the existing "no profile" error surfaces on the
        # task card without the user having to tap Do it first.
        db.update_todo(todo_id, {"status": "requested"})
        _write_activity(
            db,
            todo_id=todo_id,
            user_id=user_id,
            snapshot=AgentActivityService().initial(
                phase="starting",
                title="Starting task",
            ),
            hermes_run_id=None,
        )
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

    # Memory sync is startup tax for most preps (prep classifies, it does
    # not recall) — only stage it when the user's words reference memory.
    if _PREP_MEMORY_HINT.search(combined_text):
        memory_store = _memory_store(cfg, endpoint.profile_name)
        prep_staging_lock = gate.staging if gate is not None else asyncio.Lock()
        async with prep_staging_lock:
            with suppress(Exception):
                sync_active_memories_to_hermes(db, memory_store, user_id)

    # Skip organization examples for very short inputs — there is not
    # enough signal to match against, and the examples dominate the prompt.
    organization_examples = (
        db.get_todo_organization_examples(user_id, exclude_todo_id=todo_id)
        if len(combined_text) >= 25
        else []
    )
    # Sign attachment URLs only when the text references the image; prep
    # should not analyze images, so the count alone is enough context for
    # the title/slug. Execution always gets the real signed URLs.
    prep_attachment_urls = (
        _resolve_attachment_urls(db, todo_id)
        if attachment_rows and _PREP_IMAGE_HINT.search(combined_text)
        else None
    )

    prep_prompt = build_prepare_prompt(
        title=raw_title,
        detail=detail,
        allowed_slugs=CONNECTION_SLUGS,
        prior=prior,
        attachment_urls=prep_attachment_urls,
        organization_examples=organization_examples,
        attachment_count=len(attachment_rows),
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
        # Prep is best-effort metadata enrichment, not a gate on execution —
        # it already falls back to status=requested on timeout, so keep the
        # wait short instead of stalling the card for two minutes.
        prep_timeout = float(os.getenv("DOIT_PREP_TIMEOUT_SECS", "25"))
        final_text = await asyncio.wait_for(
            _collect_final_text(hermes, run_id),
            timeout=min(cfg.run_timeout_secs, prep_timeout),
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
        return

    # Safety nets, both keyed on the same recurrence detector so they can
    # never disagree: first demote model-hallucinated cron jobs the user
    # never asked for, then promote missed recurrence from the raw input.
    combined_input = f"{raw_title}\n{detail}".strip()
    result = demote_unrequested_cron(result, combined_input)
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
        prompt_text = detail.strip() or raw_title
        if result.summary and result.summary not in prompt_text:
            prompt_text = f"{prompt_text}\n\n{result.summary}".strip()
        converted = await _convert_prep_todo_to_cron(
            cfg,
            db,
            pusher,
            todo,
            name=result.title or raw_title,
            prompt_text=prompt_text,
            schedule=result.schedule,
            schedule_display=result.schedule_display,
            connection_slug=result.connection_slug,
            gate=gate,
        )
        if not converted:
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
        snapshot=prep_queue_snapshot(summary=result.summary),
        hermes_run_id=run_id,
    )

    # Multi-task split: insert extras as prepared todos that inherit the
    # parent's original request so execution prompts keep full context.
    # They stay at status=todo so only the primary row auto-runs — split
    # children must not surprise-start after the parent finishes.
    parent_original = (todo.get("original_title") or raw_title or "").strip()
    parent_detail = detail.strip() if detail else None
    for extra in result.additional_tasks:
        split_detail = parent_detail
        if extra.summary:
            split_detail = (
                f"From the same request: {parent_original}\n\n{extra.summary}"
                if parent_original
                else extra.summary
            )
        db.insert_prepared_todo(
            user_id=user_id,
            title=extra.title,
            original_title=parent_original or extra.title,
            detail=split_detail,
            connection_slug=extra.connection_slug,
            topic=extra.topic,
            collection_name=extra.collection_name,
            preparation_summary=extra.summary,
            spawned_by_todo_id=todo_id,
            status="todo",
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


_ACTIVITY_SYNC_LAST_PUSH: dict[str, float] = {}
_ACTIVITY_SYNC_PUSH_INTERVAL = 12.0


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


async def _notify_live_activity_sync(
    pusher: Pusher,
    db: DB,
    *,
    user_id: str,
    todo_id: str,
    snapshot: ActivitySnapshot,
) -> None:
    """Wake the iOS app briefly so it can refresh Live Activities while backgrounded."""
    if snapshot.state not in ("running", "paused"):
        return
    now = time.time()
    last = _ACTIVITY_SYNC_LAST_PUSH.get(todo_id, 0.0)
    if now - last < _ACTIVITY_SYNC_PUSH_INTERVAL:
        return
    _ACTIVITY_SYNC_LAST_PUSH[todo_id] = now
    await pusher.send_activity_sync(db.list_apns_tokens(user_id), todo_id=todo_id)


def _placeholder_gate_enforced() -> bool:
    """Whether placeholder detection blocks completion (vs log-only).

    Off by default per the rollout plan: the gate first ships log-only
    ("would have blocked") so we can review real-world hits before letting
    it flip a `done` into `needs_input`.
    """
    return os.getenv("DOIT_PLACEHOLDER_GATE", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
        "enforce",
    }


# Artifact kinds whose payloads carry outbound user-facing content (recipient
# emails, invite bodies) where placeholder text means the model invented data
# instead of using tools/memory or asking.
_PLACEHOLDER_GATED_KINDS = {"email", "calendar"}

_PLACEHOLDER_NEEDS_INPUT_PROMPT = (
    "I need the real recipient/content — the draft still has placeholder "
    "text. Can you fill in the missing details?"
)


def _structured_repair_enabled() -> bool:
    """Whether the one-shot format-repair retry is on (DOIT_STRUCTURED_REPAIR).

    Off by default: premium models almost never drop the structured blocks,
    so the extra Hermes turn would be pure cost. The flag exists to catch
    smaller-model dropouts (task finished, blocks missing).
    """
    return os.getenv("DOIT_STRUCTURED_REPAIR", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


# Tasks whose deliverable is inherently structured (an email artifact, a
# calendar invite, an approval card). A quiet "done" with none of those means
# the model did the work but dropped the contract blocks.
_STRUCTURED_OUTPUT_HINT = re.compile(
    r"\b(email|e-?mail|gmail|inbox|send|sent|reply|forward|draft|"
    r"schedule|calendar|invite|meeting|event|appointment|book|rsvp)\b",
    re.IGNORECASE,
)


def _expects_structured_output(todo: dict) -> bool:
    text = " ".join(
        str(todo.get(k) or "") for k in ("title", "detail", "topic")
    )
    return bool(_STRUCTURED_OUTPUT_HINT.search(text))


_REPAIR_PROMPT_TEMPLATE = (
    "Your previous reply finished the task but did not include the required "
    "structured output blocks. Re-emit ONLY the missing [[DOIT_INTERACTION]] "
    "or [[DOIT_ARTIFACT]] blocks for work you completed **for this specific "
    "task** (quoted below). Do not reuse artifact blocks from session_search, "
    "other todos, or unrelated prior work. Do not redo any tool work, do not "
    "call tools, and do not add any other text.\n\n"
    "Task title: {title}\n"
    "Task detail: {detail}\n"
)


def _build_repair_prompt(todo: dict) -> str:
    return _REPAIR_PROMPT_TEMPLATE.format(
        title=(todo.get("title") or "").strip(),
        detail=(todo.get("detail") or "").strip() or "(none)",
    )


async def _attempt_structured_repair(
    db: DB,
    pusher: Pusher,
    hermes: HermesClient,
    *,
    todo: dict,
    user_id: str,
    run_id: str,
    activity: AgentActivityService,
    url_tracker: RunUrlTracker | None = None,
) -> str | None:
    """One short follow-up turn to recover missing structured blocks.

    Runs on the todo's own session so the model still has its transcript;
    the prompt forbids tool work so the turn stays cheap. Returns the new
    terminal status ("needs_input" when the repair surfaced an interaction),
    "done" when artifacts were recovered, or None when nothing usable came
    back (caller keeps the original quiet `done`). Capped at one attempt per
    run by construction.
    """
    todo_id = str(todo["id"])
    log.info("repair_attempted todo=%s run=%s", todo_id, run_id)
    db.insert_step(
        todo_id=todo_id,
        user_id=user_id,
        kind="status",
        text="repair_attempted: re-requesting missing structured output",
    )
    repair_run_id: str | None = None
    try:
        repair_run_id = await hermes.start_run(
            _build_repair_prompt(todo),
            session_id=_session_id_for_todo(user_id, todo_id),
            session_key=_session_key_for_user(user_id),
        )
        final_text = await asyncio.wait_for(
            _collect_final_text(hermes, repair_run_id),
            timeout=90.0,
        )
    except Exception as e:
        log.warning("structured repair failed todo=%s: %s", todo_id, e)
        return None
    finally:
        with suppress(Exception):
            if repair_run_id is not None:
                await hermes.stop_run(repair_run_id)
    if not final_text:
        return None

    interaction = parse_interaction(final_text)
    artifacts = parse_artifacts(final_text)
    persisted = False
    for artifact in artifacts:
        # Audio/image artifacts need the full persistence pipeline (upload,
        # signing) and were not requested here — recover only the simple
        # structured kinds.
        if artifact.kind in ("audio", "image"):
            continue
        if maybe_upsert_artifact(
            db,
            todo=todo,
            artifact=artifact,
            user_id=user_id,
            run_id=run_id,
            url_tracker=url_tracker,
        ):
            persisted = True
    if interaction is not None:
        db.supersede_open_interactions(todo_id)
        db.insert_interaction(
            todo_id=todo_id,
            user_id=user_id,
            kind=interaction.kind,
            prompt=interaction.prompt,
            payload=interaction.payload,
            hermes_run_id=run_id,
        )
        db.update_todo(todo_id, {"status": "needs_input"})
        await pusher.send(
            db.list_apns_tokens(user_id),
            PushPayload(
                title="Needs your input",
                body=interaction.prompt[:160],
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
                detail=interaction.prompt,
            ),
            hermes_run_id=run_id,
        )
        return "needs_input"
    if persisted:
        log.info(
            "repair recovered %d artifact(s) todo=%s run=%s",
            len(artifacts), todo_id, run_id,
        )
        return "done"
    return None


_OUTBOUND_SEND_BLOCKED_PROMPT = (
    "Review this draft before I send it — tap Send when you're ready, "
    "or Edit to change it."
)


async def _halt_for_unauthorized_outbound_send(
    db: DB,
    pusher: Pusher,
    hermes: HermesClient,
    activity: AgentActivityService,
    *,
    todo_id: str,
    user_id: str,
    run_id: str,
    tool_name: str | None,
    draft_hint: str | None,
    live_total: int,
    stop_run: bool,
) -> str:
    """Stop a run that tried to send/post without user approval on the card."""
    log.warning(
        "outbound_send_guard: blocked unauthorized send todo=%s run=%s tool=%s",
        todo_id,
        run_id,
        tool_name,
    )
    if stop_run:
        with suppress(Exception):
            await hermes.stop_run(run_id)
    db.insert_step(
        todo_id=todo_id,
        user_id=user_id,
        kind="status",
        text=(
            "Blocked an outbound send until you approve the draft on the "
            "review card."
        ),
    )
    prior_content = None
    if draft_hint and draft_hint.strip():
        prior_content = draft_hint.strip()[:4000]
    db.supersede_open_interactions(todo_id)
    db.insert_interaction(
        todo_id=todo_id,
        user_id=user_id,
        kind="approval",
        prompt=_OUTBOUND_SEND_BLOCKED_PROMPT,
        payload=build_blocked_send_approval_payload(
            draft_hint=draft_hint,
            prior_content=prior_content,
        ),
        hermes_run_id=run_id,
    )
    db.update_todo(todo_id, {"status": "needs_input"})
    await pusher.send(
        db.list_apns_tokens(user_id),
        PushPayload(
            title="Review before sending",
            body=_OUTBOUND_SEND_BLOCKED_PROMPT[:160],
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
            title="Review before sending",
            detail=_OUTBOUND_SEND_BLOCKED_PROMPT,
        ),
        hermes_run_id=run_id,
    )
    await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)
    return "needs_input"


async def _consume_run(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    hermes: HermesClient,
    todo: dict,
    run_id: str,
    *,
    profile_name: str | None = None,
    audio_requested: bool = True,
    outbound_send_approved: bool = False,
    gate: UserGate | None = None,
) -> str:
    """Consume the SSE stream and return the terminal status.

    ``audio_requested`` reflects whether the USER's own words asked for
    spoken audio (see ``user_wants_spoken_audio``). When False, every
    audio persistence path — native text_to_speech results, the lifecycle
    TTS fallback, promoted audio-link artifacts, and explicit
    ``type:"audio"`` artifact blocks — is discarded with a
    ``tts_discarded_unrequested`` log line instead of surfacing an
    unsolicited voice memo.
    """
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
    # Track whether the run did tool work and whether it delivered anything
    # user-visible. If the SSE stream ends with neither a terminal event nor
    # a deliverable after tool work, the run died mid-flight — that must
    # surface as a failure, not a silent "Done.".
    tools_called = False
    artifacts_persisted = False
    url_tracker = RunUrlTracker()

    # Placeholder gate (Phase 4): snippets like "example.com" / "John Doe"
    # found in outbound email/calendar artifacts during this run. Checked
    # before we honor a `done` transition; log-only unless
    # DOIT_PLACEHOLDER_GATE is set.
    placeholder_hits: list[str] = []

    # Outbound send gate: block email/calendar/post tools unless the user
    # tapped Send on an approval card on this resume turn.
    outbound_send_attempted = False

    # Drives the iOS "what is Hermes doing right now?" surfaces: the
    # todo card status line, the detail-view animated cards, and the
    # Live Activity widget. `todo_steps` keeps the historic audit log.
    activity = AgentActivityService()
    latest_activity: ActivitySnapshot | None = None
    heartbeat_task: asyncio.Task | None = None

    # Progress watchdog (Phase 3a): wall-clock of the last meaningful SSE
    # event. When the gap exceeds the stall timeout the heartbeat below
    # flips the live activity to a distinct "stalled" phase (visibility
    # only — Hermes has no verified mid-run nudge channel yet) and drops
    # one step row so the transcript shows the gap too.
    stall_timeout = float(getattr(cfg, "stall_timeout_secs", 120.0) or 120.0)
    last_progress_at = time.time()
    stall_step_written = False

    async def activity_heartbeat() -> None:
        nonlocal stall_step_written
        while True:
            await asyncio.sleep(25)
            stalled = (time.time() - last_progress_at) > stall_timeout
            if stalled:
                if not stall_step_written:
                    stall_step_written = True
                    log.warning(
                        "run stalled: no progress for %.0fs todo=%s run=%s",
                        time.time() - last_progress_at, todo_id, run_id,
                    )
                    db.insert_step(
                        todo_id=todo_id,
                        user_id=user_id,
                        kind="status",
                        text="Still working — checking results…",
                    )
                snapshot = activity.stalled(latest_activity)
            else:
                snapshot = activity.heartbeat(latest_activity)
            _write_activity(
                db,
                todo_id=todo_id,
                user_id=user_id,
                snapshot=snapshot,
                hermes_run_id=run_id,
            )
            await _notify_live_activity_sync(
                pusher,
                db,
                user_id=user_id,
                todo_id=todo_id,
                snapshot=snapshot,
            )

    start_snapshot = AgentActivityService().initial(
        phase="starting",
        title="Connecting…",
        detail=None,
    )
    _write_activity(
        db,
        todo_id=todo_id,
        user_id=user_id,
        snapshot=start_snapshot,
        hermes_run_id=run_id,
    )
    await _notify_live_activity_sync(
        pusher,
        db,
        user_id=user_id,
        todo_id=todo_id,
        snapshot=start_snapshot,
    )
    heartbeat_task = asyncio.create_task(activity_heartbeat())

    try:
        async for ev in hermes.stream_events(run_id):
            effect = translate(ev.event, ev.data)
            if effect is None:
                continue
            # Any recognized effect counts as progress for the watchdog;
            # a fresh event also re-arms the one-shot stall step.
            last_progress_at = time.time()
            stall_step_written = False
            if effect.step_kind in ("tool_started", "tool_result"):
                tools_called = True
            if (
                not outbound_send_approved
                and is_outbound_send_tool(effect.tool_name)
                and effect.step_kind in ("tool_started", "tool_result")
            ):
                outbound_send_attempted = True
                if effect.step_kind == "tool_started":
                    return await _halt_for_unauthorized_outbound_send(
                        db,
                        pusher,
                        hermes,
                        activity,
                        todo_id=todo_id,
                        user_id=user_id,
                        run_id=run_id,
                        tool_name=effect.tool_name,
                        draft_hint=effect.text,
                        live_total=live_total,
                        stop_run=True,
                    )
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
                await _notify_live_activity_sync(
                    pusher,
                    db,
                    user_id=user_id,
                    todo_id=todo_id,
                    snapshot=snap,
                )
            if effect.step_kind == "tool_result":
                url_tracker.observe_tool_result(ev.data)

            # Persist artifacts before any terminal `break` below so a `done`
            # event that also carries deliverables still lands them in the DB.
            artifact_text = _first_text_artifact_body(effect.artifacts) or effect.text
            for artifact in effect.artifacts:
                if not audio_requested and (
                    artifact.kind == "audio"
                    or _looks_like_audio_link_artifact(artifact)
                ):
                    log.info(
                        "tts_discarded_unrequested artifact todo=%s run=%s kind=%s key=%s",
                        todo_id, run_id, artifact.kind, artifact.key,
                    )
                    continue
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
                if artifact.kind in _PLACEHOLDER_GATED_KINDS:
                    hits = find_placeholder_matches(
                        {"title": artifact.title, "payload": artifact.payload}
                    )
                    if hits:
                        placeholder_hits.extend(
                            h for h in hits if h not in placeholder_hits
                        )
                if maybe_upsert_artifact(
                    db,
                    todo=todo,
                    artifact=artifact,
                    user_id=user_id,
                    run_id=run_id,
                    url_tracker=url_tracker,
                ):
                    artifacts_persisted = True
            if effect.tts_call is not None:
                pending_tts[effect.tts_call.call_id] = effect.tts_call
                pending_tts_started_at[effect.tts_call.call_id] = time.time() - 10
            if effect.tts_result is not None:
                if not audio_requested:
                    log.info(
                        "tts_discarded_unrequested tool_result todo=%s run=%s call_id=%s",
                        todo_id, run_id, effect.tts_result.call_id,
                    )
                else:
                    _persist_tts_audio(
                        db,
                        todo_id=todo_id,
                        user_id=user_id,
                        run_id=run_id,
                        result=effect.tts_result,
                        call=pending_tts.get(effect.tts_result.call_id),
                    )
                    artifacts_persisted = True
                lifecycle_tts_uploaded = True
            if (
                effect.step_kind == "tool_result"
                and effect.tool_name == "text_to_speech"
                and not lifecycle_tts_uploaded
            ):
                if not audio_requested:
                    log.info(
                        "tts_discarded_unrequested lifecycle todo=%s run=%s",
                        todo_id, run_id,
                    )
                    lifecycle_tts_uploaded = True
                else:
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
            if (
                effect.new_status == "done"
                and outbound_send_attempted
                and not outbound_send_approved
            ):
                # Send tool completed before we could abort on tool_started,
                # or the model marked done after an unauthorized send attempt.
                return await _halt_for_unauthorized_outbound_send(
                    db,
                    pusher,
                    hermes,
                    activity,
                    todo_id=todo_id,
                    user_id=user_id,
                    run_id=run_id,
                    tool_name=effect.tool_name,
                    draft_hint=(
                        "The agent attempted to send without your approval. "
                        "Review the draft before trying again."
                    ),
                    live_total=live_total,
                    stop_run=False,
                )
            if effect.new_status == "done" and placeholder_hits:
                if _placeholder_gate_enforced():
                    # The model is trying to complete with fake content in an
                    # outbound draft (invented email, lorem ipsum, template
                    # brackets). Pause for real details instead of "Done.".
                    log.warning(
                        "placeholder_gate: blocking done todo=%s run=%s matches=%s",
                        todo_id, run_id, placeholder_hits[:10],
                    )
                    db.supersede_open_interactions(todo_id)
                    db.insert_interaction(
                        todo_id=todo_id,
                        user_id=user_id,
                        kind="question",
                        prompt=_PLACEHOLDER_NEEDS_INPUT_PROMPT,
                        payload={
                            "freeform": True,
                            "placeholder_matches": placeholder_hits[:10],
                        },
                        hermes_run_id=run_id,
                    )
                    db.update_todo(todo_id, {"status": "needs_input"})
                    await pusher.send(
                        db.list_apns_tokens(user_id),
                        PushPayload(
                            title="Needs your input",
                            body=_PLACEHOLDER_NEEDS_INPUT_PROMPT[:160],
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
                            detail=_PLACEHOLDER_NEEDS_INPUT_PROMPT,
                        ),
                        hermes_run_id=run_id,
                    )
                    await _reconcile_run_tokens(
                        db, hermes, todo_id, run_id, live_total
                    )
                    return "needs_input"
                log.warning(
                    "placeholder_gate: would have blocked done todo=%s run=%s "
                    "matches=%s",
                    todo_id, run_id, placeholder_hits[:10],
                )
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
                    if effect.interaction.kind == "approval":
                        # Log-only here: the approval card pauses for human
                        # review anyway, but the hit rate tells us how often
                        # drafts reach the user with fake content.
                        draft_hits = find_placeholder_matches(
                            effect.interaction.payload
                        )
                        if draft_hits:
                            log.warning(
                                "placeholder_gate: approval draft has "
                                "placeholder content todo=%s run=%s matches=%s",
                                todo_id, run_id, draft_hits[:10],
                            )
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

    if (
        terminal == "done"
        and not artifacts_persisted
        and _structured_repair_enabled()
        and _expects_structured_output(todo)
    ):
        if gate is not None and gate.active_exec > 1:
            log.info(
                "repair_skipped_concurrent todo=%s run=%s active_exec=%s",
                todo_id,
                run_id,
                gate.active_exec,
            )
        else:
            # The task is the kind that should end in an email/calendar artifact
            # or an approval card, but the run completed with neither — the model
            # likely did the work and dropped the contract blocks. One cheap
            # repair turn (no tools) on the same session re-requests them.
            repaired = await _attempt_structured_repair(
                db,
                pusher,
                hermes,
                todo=todo,
                user_id=user_id,
                run_id=run_id,
                activity=activity,
                url_tracker=url_tracker,
            )
            if repaired == "needs_input":
                await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)
                return "needs_input"
            if repaired == "done":
                artifacts_persisted = True

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
        if tools_called and not artifacts_persisted:
            # The agent did tool work and then the stream ended with no
            # final text, no artifacts, and no interaction. That is a run
            # that died mid-flight (model gave up, provider dropped the
            # stream, ...). Marking it "Done." would silently swallow the
            # failure — surface it so the user can retry or ask.
            log.warning(
                "run ended without terminal event or deliverable; failing "
                "todo=%s run=%s",
                todo_id,
                run_id,
            )
            failure_text = (
                "The agent stopped before finishing. Tap to retry or ask "
                "what happened."
            )
            db.insert_step(
                todo_id=todo_id,
                user_id=user_id,
                kind="error",
                text=failure_text,
            )
            db.update_todo(
                todo_id,
                {"status": "failed", "error_message": failure_text},
            )
            _write_activity(
                db,
                todo_id=todo_id,
                user_id=user_id,
                snapshot=activity.mark_terminal(
                    state="failed",
                    phase="failed",
                    title="Stopped early",
                    detail=failure_text,
                ),
                hermes_run_id=run_id,
            )
            terminal = "failed"
        else:
            # No tool work happened (trivial run) or deliverables already
            # landed mid-stream — treat the quiet stream end as success
            # rather than leaving the todo stuck in running.
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


# A short read-only query/listing task: starts with a lookup verb and never
# mentions creating, sending, or changing anything. Running a second Hermes
# pass to mine memories out of "List the Github repos you have access to"
# costs a full LLM call and mostly produces junk suggestions.
_TRIVIAL_READONLY_LEAD = re.compile(
    r"^\s*(?:can you |could you |please )?"
    r"(?:list|show(?:\s+me)?|what(?:'s|\s+is|\s+are)?|how\s+many|count|"
    r"check|look\s*up|tell\s+me|get|fetch|display|read)\b",
    re.IGNORECASE,
)

_MUTATING_WORDS = re.compile(
    r"\b(?:send|create|draft|write|book|schedule|post|update|delete|remove|"
    r"add|make|build|buy|order|reserve|invite|upload|reply|email\s+\w+|"
    r"remind|note|save|remember|set\s+up)\b",
    re.IGNORECASE,
)


def _is_trivial_readonly_todo(todo: dict) -> bool:
    """True for short lookup/listing tasks not worth a memory-extraction run."""
    combined = " ".join(
        str(todo.get(k) or "").strip()
        for k in ("original_title", "title", "detail")
    ).strip()
    if not combined or len(combined) > 220:
        return False
    lead_text = str(
        todo.get("original_title") or todo.get("title") or ""
    ).strip()
    if not _TRIVIAL_READONLY_LEAD.match(lead_text):
        return False
    return not _MUTATING_WORDS.search(combined)


def _memory_model_override() -> str | None:
    """Fixed cheap model for post-task memory extraction (DOIT_MEMORY_MODEL).

    Unset by default: extraction reuses the user's Hermes profile model.
    When set, the runner calls the model directly (extraction is JSON-only,
    no tools) so a GPT 5.5 agent doesn't pay 5.5 prices to mine memories.
    """
    model = os.getenv("DOIT_MEMORY_MODEL", "").strip()
    return model or None


async def _extract_memories_text_direct(prompt: str, *, model: str) -> str | None:
    """Run the extraction prompt against a fixed model via chat completions.

    Hermes has no per-run model override (model choice is profile-level in
    config.yaml), but extraction needs no tools or session state — a plain
    chat-completions call is equivalent. OpenRouter is preferred (handles
    cross-provider slugs like "google/gemini-..."), OpenAI is the fallback.
    Returns ``None`` on any failure so the caller falls back to the normal
    Hermes-profile extraction run.
    """
    api_key = os.getenv("OPENROUTER_API_KEY", "").strip()
    url = "https://openrouter.ai/api/v1/chat/completions"
    if not api_key:
        api_key = os.getenv("OPENAI_API_KEY", "").strip()
        url = "https://api.openai.com/v1/chat/completions"
    if not api_key:
        log.warning(
            "DOIT_MEMORY_MODEL=%s set but no OPENROUTER_API_KEY/OPENAI_API_KEY; "
            "falling back to Hermes extraction",
            model,
        )
        return None
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": MEMORY_EXTRACT_INSTRUCTIONS},
            {"role": "user", "content": prompt},
        ],
    }
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                url,
                json=payload,
                headers={"Authorization": f"Bearer {api_key}"},
            )
            resp.raise_for_status()
            data = resp.json()
        choices = data.get("choices") or []
        message = (choices[0] if choices else {}).get("message") or {}
        return str(message.get("content") or "")
    except Exception as e:
        log.warning("direct memory extraction failed model=%s: %s", model, e)
        return None


async def _extract_memories_after_todo(
    db: DB,
    todo: dict,
    *,
    endpoint,
    memory_store: HermesMemoryStore,
    staging_lock: asyncio.Lock | None = None,
) -> None:
    """Run Doit's post-task memory extraction pass for a completed todo."""
    todo_id = str(todo["id"])
    user_id = str(todo["user_id"])
    if _is_trivial_readonly_todo(todo):
        log.info("memory extraction skipped for trivial todo %s", todo_id)
        return
    settings = db.get_memory_settings(user_id)
    if settings.get("automatic_suggestions_enabled") is False:
        return
    existing_memories = db.list_memories_for_extraction_context(user_id)
    prompt = build_memory_extraction_prompt(
        todo=todo,
        task_context=_task_context_for_prompt(db, todo_id),
        existing_memories=existing_memories,
        custom_instructions=settings.get("custom_instructions"),
    )

    final_text: str | None = None
    memory_model = _memory_model_override()
    if memory_model:
        final_text = await _extract_memories_text_direct(
            prompt, model=memory_model
        )
    if final_text is None:
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
        db.upsert_extracted_memory(
            user_id=user_id,
            target=candidate.target,
            title=candidate.title,
            body=candidate.body,
            confidence=candidate.confidence,
            reason=candidate.reason,
            source_todo_id=todo_id,
            memory_status=storage_status_for_extracted_memory(candidate),
            symbol_name=candidate.symbol_name,
        )
    # The extraction LLM call above runs unlocked; only the profile-file
    # rewrite needs the per-user staging lock.
    if staging_lock is not None:
        async with staging_lock:
            sync_active_memories_to_hermes(db, memory_store, user_id)
    else:
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
        protected = frozenset(
            row["hermes_fingerprint"]
            for row in db.list_synced_memories(user_id)
            if row.get("source") == "user"
            and row.get("target") == target
            and row.get("hermes_fingerprint")
        )
        try:
            _, skipped = store.stage_pinned_entries(
                target, texts, protected_fingerprints=protected
            )
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


# How often a running todo's execution lease is refreshed. Must be well
# under the claim-stale window (15 min) so healthy runs are never stolen.
_RUN_LEASE_HEARTBEAT_SECS = 60.0

# How often the loop scans for work stranded by a crashed runner (todos /
# cron jobs stuck in `running` with an expired lease).
_STALE_SCAN_INTERVAL_SECS = 30.0

# How often the loop polls user_provisioning for pending signups. Kept low:
# provisioning is rare, and the onboarding screen sets expectations of
# "about a minute".
_PROVISION_POLL_INTERVAL_SECS = 10.0


async def _run_lease_heartbeat(db: DB, todo_id: str) -> None:
    while True:
        await asyncio.sleep(_RUN_LEASE_HEARTBEAT_SECS)
        db.touch_todo_run_lease(todo_id)


async def _execute_claimed_todo(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    todo: dict,
    gates: UserGates,
) -> None:
    """Pool wrapper: per-user accounting + lease heartbeat around one todo."""
    user_id = str(todo["user_id"])
    todo_id = str(todo["id"])
    gate = gates.get(user_id)
    gate.active_total += 1
    gate.active_exec += 1
    heartbeat = asyncio.create_task(_run_lease_heartbeat(db, todo_id))
    try:
        await run_one_todo(cfg, db, pusher, todo, gate=gate)
    except Exception:
        log.exception("run_one_todo crashed for %s", todo_id)
    finally:
        heartbeat.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await heartbeat
        gate.active_total -= 1
        gate.active_exec -= 1
        gates.release_if_idle(user_id)


async def _prepare_claimed_todo(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    todo: dict,
    gates: UserGates,
) -> None:
    user_id = str(todo["user_id"])
    gate = gates.get(user_id)
    gate.active_total += 1
    try:
        await prepare_one_todo(cfg, db, pusher, todo, gate=gate)
    except Exception:
        log.exception("prepare_one_todo crashed for %s", todo.get("id"))
    finally:
        gate.active_total -= 1
        gates.release_if_idle(user_id)


async def _configure_claimed_cron_job(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    job: dict,
    gates: UserGates,
) -> None:
    user_id = str(job["user_id"])
    gate = gates.get(user_id)
    gate.active_total += 1
    try:
        await configure_one_cron_job(cfg, db, pusher, job, gate=gate)
    except Exception:
        log.exception("configure_one_cron_job crashed for %s", job.get("id"))
    finally:
        gate.active_total -= 1
        gates.release_if_idle(user_id)


async def _execute_claimed_cron_job(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    job: dict,
    gates: UserGates,
) -> None:
    user_id = str(job["user_id"])
    gate = gates.get(user_id)
    gate.active_total += 1
    gate.active_exec += 1
    try:
        await run_one_cron_job(cfg, db, pusher, job)
    except Exception:
        log.exception("cron job crashed for %s", job.get("id"))
    finally:
        gate.active_total -= 1
        gate.active_exec -= 1
        gates.release_if_idle(user_id)


async def _provision_claimed_user(cfg: Config, db: DB, row: dict) -> None:
    # Blocking work (subprocess + HTTP) runs in a thread so SSE consumption
    # for in-flight runs never stalls behind a provisioning pass.
    await asyncio.to_thread(run_provisioning, cfg, db, row)


async def main_loop() -> None:
    setup_logging()
    cfg = load()
    db = DB(cfg)
    pusher = Pusher(cfg)
    gates = UserGates()
    pool = TaskPool(cfg.max_concurrent_runs)
    log.info(
        "doit runner online; polling every %ss "
        "(max %d concurrent work items, %d execution slots per user)",
        cfg.poll_interval_secs,
        cfg.max_concurrent_runs,
        cfg.max_runs_per_user,
    )
    last_stale_scan = 0.0
    last_provision_scan = 0.0

    while True:
        if not pool.has_capacity:
            # Pool is full: block until any work item finishes (or the poll
            # interval elapses) instead of hammering the claim queries.
            await pool.wait_for_capacity(cfg.poll_interval_secs)
            continue

        capped_users = gates.users_at_exec_cap(cfg.max_runs_per_user)

        # Preparation is short and user-facing (the card spinner sits there
        # until we finish), so it gets first dibs each tick.
        try:
            prep_todo = db.claim_next_preparing_todo()
        except Exception:
            log.exception("prep claim failed; will retry")
            prep_todo = None
        if prep_todo is not None:
            pool.spawn(
                _prepare_claimed_todo(cfg, db, pusher, prep_todo, gates),
                name=f"prep:{prep_todo['id']}",
            )
            continue

        # New-user provisioning (low-frequency poll; the onboarding screen
        # is watching the user_provisioning row over Realtime).
        if (
            cfg.provisioner_enabled
            and time.time() - last_provision_scan >= _PROVISION_POLL_INTERVAL_SECS
        ):
            last_provision_scan = time.time()
            prov_row = db.claim_next_provisioning_user()
            if prov_row is not None:
                pool.spawn(
                    _provision_claimed_user(cfg, db, prov_row),
                    name=f"provision:{prov_row['user_id']}",
                )
                continue

        try:
            cfg_job = db.claim_next_configuring_cron_job()
        except Exception:
            log.exception("cron configure claim failed")
            cfg_job = None
        if cfg_job is not None:
            pool.spawn(
                _configure_claimed_cron_job(cfg, db, pusher, cfg_job, gates),
                name=f"cron-config:{cfg_job['id']}",
            )
            continue

        try:
            due_jobs = db.claim_due_cron_jobs(
                limit=1, exclude_user_ids=capped_users
            )
        except Exception:
            log.exception("cron claim failed")
            due_jobs = []
        if due_jobs:
            pool.spawn(
                _execute_claimed_cron_job(cfg, db, pusher, due_jobs[0], gates),
                name=f"cron:{due_jobs[0]['id']}",
            )
            continue

        try:
            todo = db.claim_next_requested_todo(exclude_user_ids=capped_users)
        except Exception:
            log.exception("claim failed; will retry")
            todo = None

        # Periodically recover work stranded in `running` by a crashed
        # runner (stale execution lease).
        if todo is None:
            now = time.time()
            if now - last_stale_scan >= _STALE_SCAN_INTERVAL_SECS:
                last_stale_scan = now
                todo = db.claim_stale_running_todo(exclude_user_ids=capped_users)
                if todo is None:
                    stale_job = db.claim_stale_running_cron_job(
                        exclude_user_ids=capped_users
                    )
                    if stale_job is not None:
                        pool.spawn(
                            _execute_claimed_cron_job(
                                cfg, db, pusher, stale_job, gates
                            ),
                            name=f"cron-recovered:{stale_job['id']}",
                        )
                        continue

        if todo is not None:
            pool.spawn(
                _execute_claimed_todo(cfg, db, pusher, todo, gates),
                name=f"todo:{todo['id']}",
            )
            continue

        await asyncio.sleep(cfg.poll_interval_secs)


def main() -> None:
    asyncio.run(main_loop())


if __name__ == "__main__":
    main()
