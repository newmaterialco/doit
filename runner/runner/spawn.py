"""Apply agent-requested todo spawns from [[DOIT_TASKS]] blocks."""
from __future__ import annotations

import logging

from .db import DB
from .events import SpawnedTaskRequest
from .prepare import CONNECTION_SLUGS

log = logging.getLogger(__name__)


def apply_spawned_tasks(
    db: DB,
    user_id: str,
    tasks: list[SpawnedTaskRequest],
    *,
    source_todo_id: str | None = None,
    source_cron_job_id: str | None = None,
    allowed_slugs: frozenset[str] | set[str] = CONNECTION_SLUGS,
) -> int:
    """Insert spawn rows as ``status=todo``. Returns count inserted."""
    if not tasks:
        return 0
    inserted = 0
    for task in tasks:
        slug = task.connection_slug
        if slug and slug not in allowed_slugs:
            slug = None
        if db.spawn_key_exists(user_id, task.source_key):
            log.info(
                "spawn skip duplicate source_key=%r user=%s",
                task.source_key,
                user_id,
            )
            continue
        if db.spawned_todo_title_exists(
            user_id,
            task.title,
            source_todo_id=source_todo_id,
            source_cron_job_id=source_cron_job_id,
        ):
            log.info(
                "spawn skip duplicate title=%r user=%s source_todo=%s source_cron=%s",
                task.title,
                user_id,
                source_todo_id,
                source_cron_job_id,
            )
            continue
        row = db.insert_spawned_todo(
            user_id=user_id,
            title=task.title,
            original_title=task.title,
            detail=task.detail,
            connection_slug=slug,
            preparation_summary=task.summary,
            spawn_key=task.source_key,
            spawned_by_todo_id=source_todo_id,
            spawned_by_cron_job_id=source_cron_job_id,
        )
        if row:
            inserted += 1
            log.info(
                "spawned todo %s from source_key=%r",
                row.get("id"),
                task.source_key,
            )
    return inserted
