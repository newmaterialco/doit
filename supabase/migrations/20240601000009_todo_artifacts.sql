-- Agent-produced artifacts for todos.
--
-- When the agent finishes (or makes meaningful progress on) a task it may
-- return a "deliverable" the user should see at a glance — a created Google
-- Sheet / Doc link, a sent email summary, a calendar invite, or a short
-- text result. These render as a compact card under the task title in the
-- detail view.
--
-- The agent emits one `[[DOIT_ARTIFACT]] {json} [[/DOIT_ARTIFACT]]` block per
-- artifact in its final reply. The runner parses those blocks (see
-- ``runner/runner/events.py``) and upserts a row here keyed on
-- ``(todo_id, artifact_key)`` so the agent can update a previously-emitted
-- artifact (e.g. replace a draft URL with a final published one) without
-- duplicating cards.
--
-- ``todo_steps`` remains the append-only activity log; ``todo_artifacts``
-- is the small set of user-visible deliverables.

-- =========================================================================
-- Table
-- =========================================================================

create table todo_artifacts (
    id              uuid primary key default gen_random_uuid(),
    todo_id         uuid not null references todos(id) on delete cascade,
    user_id         uuid not null references auth.users(id) on delete cascade,
    -- Stable per-todo key the agent reuses to update an artifact in place.
    -- Defaults to the kind on the runner side when the agent omits one.
    artifact_key    text not null check (char_length(artifact_key) between 1 and 64),
    -- The renderer on iOS switches on this; keep in sync with
    -- ``ArtifactKind`` in ``ios/doit/doit/Models/TodoArtifact.swift`` and
    -- ``parse_artifacts`` in ``runner/runner/events.py``.
    kind            text not null check (kind in ('link', 'email', 'calendar', 'text')),
    -- Short human-readable label rendered as the card title. Optional —
    -- some artifact kinds (text) carry their own headline in the payload.
    title           text check (title is null or char_length(title) between 1 and 200),
    -- Type-specific payload. Free-form jsonb so we can iterate on the
    -- per-kind shape without migrating. Conventions (not enforced):
    --   link     -> { "url": "...", "provider": "googlesheets" }
    --   email    -> { "to": ["..."], "subject": "...", "body": "..." }
    --   calendar -> { "title": "...", "start": "...", "end": "...",
    --                 "location": "...", "attendees": ["..."], "url": "..." }
    --   text     -> { "text": "..." }
    payload         jsonb not null default '{}'::jsonb,
    hermes_run_id   text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    unique (todo_id, artifact_key)
);

create index todo_artifacts_todo_id_idx
    on todo_artifacts (todo_id, created_at);

create trigger todo_artifacts_set_updated_at
    before update on todo_artifacts
    for each row execute function set_updated_at();

-- =========================================================================
-- Row-Level Security
-- =========================================================================
-- Users have full CRUD on their own artifact rows (delete is useful so the
-- iOS app can dismiss a stale artifact). The runner uses service_role to
-- upsert across users.

alter table todo_artifacts enable row level security;

create policy "todo_artifacts_self_select" on todo_artifacts
    for select using (auth.uid() = user_id);

create policy "todo_artifacts_self_insert" on todo_artifacts
    for insert with check (auth.uid() = user_id);

create policy "todo_artifacts_self_update" on todo_artifacts
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "todo_artifacts_self_delete" on todo_artifacts
    for delete using (auth.uid() = user_id);

-- =========================================================================
-- Realtime
-- =========================================================================

alter publication supabase_realtime add table todo_artifacts;
