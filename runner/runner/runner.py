"""Main poll loop: claim requested todos, drive Hermes, stream steps + push."""
from __future__ import annotations

import asyncio
import logging
from contextlib import suppress
from datetime import UTC, datetime
from typing import Any

import httpx

from .config import Config, load
from .db import DB
from .events import extract_terminal_text, extract_usage_total, translate
from .hermes import HermesClient
from .hermes_memory import (
    HermesMemoryStore,
    MemoryTarget,
    fingerprint as memory_fingerprint,
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
    prep_session_id_for_user as _prep_session_id_for_user,
    session_id_for_user as _session_id_for_user,
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

    if resume is not None:
        response = resume.get("response") or {}
        option_id = str(response.get("option_id") or "").lower()
        # Mark the responded row as superseded right away so that we don't
        # accidentally replay this same answer on a future "Do it" of the
        # same todo. The response payload itself is preserved on the row.
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
            # Drop any unsent messages too; the user just cancelled the task.
            if pending_ids:
                db.mark_user_messages_consumed(pending_ids)
            return
        prompt = _build_resume_prompt(
            title=title,
            detail=detail,
            interaction=resume,
            original_title=original_title,
            preparation_summary=preparation_summary,
            connection_slug=connection_slug,
            attachment_urls=attachment_urls,
        )
        # If the user happened to also type a free-form message alongside
        # the interaction response, tack it onto the same prompt so the
        # agent sees both pieces in one turn.
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
        )

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

    try:
        setting = db.get_pending_agent_model_setting(user_id)
        if setting is not None:
            AgentModelApplier(cfg).apply(endpoint.profile_name, setting)
            db.update_agent_model_status(user_id, status="applied")
    except Exception as e:
        log.exception("failed to apply model setting for user %s", user_id)
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

    # Push any newly-pinned user memories into Hermes' USER.md / MEMORY.md so
    # they land in the next session's frozen snapshot. This runs before the
    # /v1/runs call on purpose — Hermes loads memory at session start.
    memory_store = HermesMemoryStore(cfg.hermes_profiles_dir, endpoint.profile_name)
    _sync_pending_memories_to_hermes(db, memory_store, user_id)

    hermes = HermesClient(endpoint)
    cancel_watcher: asyncio.Task | None = None
    run_id: str | None = None
    session_id = _session_id_for_user(user_id)
    terminal_status: str | None = None

    try:
        run_id = await hermes.start_run(prompt, session_id=session_id)
        db.update_todo(
            todo_id,
            {"hermes_run_id": run_id, "hermes_session_id": session_id},
        )
        log.info(
            "todo %s started run %s on session %s",
            todo_id,
            run_id,
            session_id,
        )

        cancel_event = asyncio.Event()
        cancel_watcher = asyncio.create_task(
            _watch_for_cancel(cfg, db, todo_id, cancel_event)
        )

        consume_task = asyncio.create_task(
            _consume_run(cfg, db, pusher, hermes, todo, run_id)
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

    except httpx.HTTPError as e:
        log.exception("hermes call failed for todo %s", todo_id)
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
    except Exception as e:
        log.exception("unexpected failure processing todo %s", todo_id)
        terminal_status = "failed"
        db.update_todo(
            todo_id,
            {"status": "failed", "error_message": str(e)},
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
            _mirror_hermes_memory_to_supabase(db, memory_store, user_id)

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
    moves to ``status='todo'`` (ready); on a clarification it moves to
    ``status='needs_input'`` with a prep-phase interaction.

    Failure modes are intentionally non-fatal: if Hermes is unreachable, the
    prep JSON is missing/malformed, or we time out, we still flip the todo
    to ``todo`` so the user can decide to tap "Do it" with their original
    wording. Preparation is best-effort UX, not a gate on execution.
    """
    todo_id = todo["id"]
    user_id = todo["user_id"]
    raw_title = todo["title"]
    detail = todo.get("detail") or ""

    log.info("preparing todo %s user=%s title=%r", todo_id, user_id, raw_title)

    # Preserve the user's original wording the first time we touch this row.
    if not todo.get("original_title"):
        db.update_todo(todo_id, {"original_title": raw_title})

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
        # No Hermes for this user yet: skip prep and let the existing
        # execution path surface the "no profile" error when they tap Do it.
        db.update_todo(todo_id, {"status": "todo"})
        return

    memory_store = HermesMemoryStore(cfg.hermes_profiles_dir, endpoint.profile_name)
    with suppress(Exception):
        _sync_pending_memories_to_hermes(db, memory_store, user_id)

    prep_prompt = build_prepare_prompt(
        title=raw_title,
        detail=detail,
        allowed_slugs=CONNECTION_SLUGS,
        prior=prior,
        attachment_urls=_resolve_attachment_urls(db, todo_id),
    )
    session_id = _prep_session_id_for_user(user_id)

    hermes = HermesClient(endpoint)
    run_id: str | None = None
    final_text: str | None = None
    try:
        run_id = await hermes.start_run(
            prep_prompt,
            session_id=session_id,
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
        # Couldn't get usable prep — proceed without it so the user isn't stuck.
        log.info("prep produced no result for todo %s; marking ready", todo_id)
        db.update_todo(todo_id, {"status": "todo"})
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
    if result.summary:
        updates["preparation_summary"] = result.summary

    if result.needs_clarification:
        # Persist the prep fields we do have, flip to needs_input, and open
        # one interaction with phase='prepare' so the resume routes back to
        # this preparation flow (not into execution).
        updates["status"] = "needs_input"
        db.update_todo(todo_id, updates)

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

        nxt = compute_next_run(result.schedule)
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

    # Ready — flip to 'todo' so the card shows the Do it button.
    updates["status"] = "todo"
    db.update_todo(todo_id, updates)

    # Multi-task split: insert extras as already-prepared todos.
    for extra in result.additional_tasks:
        db.insert_prepared_todo(
            user_id=user_id,
            title=extra.title,
            original_title=extra.title,
            detail=None,
            connection_slug=extra.connection_slug,
            preparation_summary=extra.summary,
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


async def _consume_run(
    cfg: Config,
    db: DB,
    pusher: Pusher,
    hermes: HermesClient,
    todo: dict,
    run_id: str,
) -> str:
    """Consume the SSE stream and return the terminal status."""
    todo_id = todo["id"]
    user_id = todo["user_id"]
    terminal: str | None = None
    # Sum of per-turn usage we've already pushed to `todos.total_tokens`
    # for THIS run. Used to compute a delta against the authoritative
    # run total when the SSE stream ends.
    live_total: int = 0

    async for ev in hermes.stream_events(run_id):
        effect = translate(ev.event, ev.data)
        if effect is None:
            continue
        if effect.step_kind:
            db.insert_step(
                todo_id=todo_id,
                user_id=user_id,
                kind=effect.step_kind,
                text=effect.text,
                url=effect.url,
                tool_name=effect.tool_name,
            )
        # Persist artifacts before any terminal `break` below so a `done`
        # event that also carries deliverables still lands them in the DB.
        for artifact in effect.artifacts:
            db.upsert_artifact(
                todo_id=todo_id,
                user_id=user_id,
                key=artifact.key,
                kind=artifact.kind,
                title=artifact.title,
                payload=artifact.payload,
                hermes_run_id=run_id,
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
                await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)
                return "needs_input"

            if effect.new_status in ("done", "failed"):
                terminal = effect.new_status
                # Drain until the stream actually closes so we don't miss tail
                # events, but with a small grace.
                break

    if terminal is None:
        db.insert_step(
            todo_id=todo_id,
            user_id=user_id,
            kind="final",
            text="Done.",
        )
        db.update_todo(todo_id, {"status": "done"})
        terminal = "done"

    if terminal in ("done", "failed"):
        db.supersede_open_interactions(todo_id)

    await _reconcile_run_tokens(db, hermes, todo_id, run_id, live_total)

    return terminal


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


def _sync_pending_memories_to_hermes(
    db: DB,
    store: HermesMemoryStore,
    user_id: str,
) -> None:
    """Write the user's pinned memories into Hermes' USER.md / MEMORY.md.

    User-authored rows in Supabase carry ``source='user'`` and start at
    ``sync_status='pending'``. We group them by target, stage them into the
    matching file (preserving everything already there), then update each
    row to ``synced`` with the fingerprint of the text we wrote so the
    reverse-direction mirror (Hermes -> Supabase) won't duplicate them.
    """
    pending = db.list_memories_for_sync(user_id)
    if not pending:
        return

    by_target: dict[MemoryTarget, list[dict]] = {"user": [], "memory": []}
    for row in pending:
        target = row.get("target") or "user"
        if target not in by_target:
            target = "user"
        by_target[target].append(row)

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
