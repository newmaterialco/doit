-- Live agent activity snapshot for each todo.
--
-- `todo_steps` is an append-only audit log of every Hermes SSE event we
-- recognized. `todo_agent_activity` is the *current* picture: one row per
-- active todo describing what Hermes is doing right now. The iOS app reads
-- this snapshot to drive three surfaces:
--
--   1. The status line on the todo card ("Searching Gmail…").
--   2. The animated activity card pinned at the top of the task detail view.
--   3. The Live Activity widget on the Lock Screen / Dynamic Island.
--
-- All three surfaces want the same canonical labels, icons, and timestamps,
-- so we compute them once in the runner (`runner/runner/activity.py`) and
-- store the normalized snapshot here. The iOS app does no SSE parsing.
--
-- Lifecycle:
--   - Runner upserts on every Hermes SSE event it recognizes. State is one
--     of `running` / `paused` / `completed` / `failed` so the UI can clear
--     "Working on…" copy when a run actually finishes (instead of staring
--     at a stale label).
--   - The previous activity for a todo is overwritten in place (one row per
--     todo) — we don't keep history here. Use `todo_steps` for history.
--
-- See `docs/task-realtime.md` for how this flows into the iOS `TodoStore`.

-- =========================================================================
-- Table
-- =========================================================================

create table todo_agent_activity (
    -- One activity per todo. Using `todo_id` as the PK keeps upserts cheap
    -- and guarantees no duplicate "current state" rows.
    todo_id         uuid primary key references todos(id) on delete cascade,
    user_id         uuid not null references auth.users(id) on delete cascade,
    hermes_run_id   text,

    -- Coarse phase of the agent loop. Free-form text (not an enum) so the
    -- runner can iterate on phase taxonomy without migrations. Conventions:
    --   'preparing'  - the prep pass is rewriting the title / picking a slug
    --   'starting'   - run created, waiting on the first model token
    --   'thinking'   - reasoning step (we sanitize the text before storing)
    --   'tool'       - a tool is currently executing
    --   'tool_done'  - tool completed; we briefly surface the result label
    --   'final'      - producing the final assistant reply
    --   'idle'       - between turns; nothing to surface
    --   'completed'  - run terminated successfully
    --   'failed'     - run terminated with an error
    --   'needs_input' / 'needs_auth' - paused on the user
    phase           text not null,

    -- Liveness of the activity. Drives whether the UI shows the running
    -- shimmer animation or a settled "done" / "paused" card.
    --   'running'    - actively progressing
    --   'paused'     - waiting on the user (OAuth, needs_input)
    --   'completed'  - terminal happy path
    --   'failed'     - terminal sad path
    state           text not null,

    -- Short human-readable label (≤120 chars) the UI shows as the current
    -- intent: "Searching Gmail", "Drafting reply", "Spoken summary ready".
    -- Always present so the card never renders an empty line.
    title           text not null check (char_length(title) between 1 and 200),

    -- Optional secondary line. Often the safe preview of the tool args or
    -- a short result snippet. NULL when there's nothing extra to say.
    detail          text check (detail is null or char_length(detail) between 1 and 400),

    -- Active tool's canonical Hermes/Composio name (e.g. `gmail_search`).
    -- NULL when we're between tools.
    tool_name       text,
    -- Hermes `call_id` for the in-flight tool, so a `tool_started` event
    -- can be paired with its matching `tool_result` even when several
    -- tools run in parallel.
    tool_call_id    text,
    -- Coarse category used by the iOS app to pick an SF Symbol.
    -- Conventions: 'gmail', 'calendar', 'sheets', 'docs', 'search',
    --             'browser', 'audio', 'oauth', 'thinking', 'unknown'.
    tool_category   text,

    -- Recent normalized steps so the widget/detail card can show a short
    -- stack of "previous intent" / "second previous intent" cards à la
    -- the Chowder layout, without iOS having to scan `todo_steps`.
    -- Shape: { "steps": [{ "title": "...", "detail": "...",
    --                       "tool_name": "...", "tool_category": "...",
    --                       "started_at": "...", "completed_at": "..." },
    --                     ...] }
    -- Capped to the most recent 8 entries by the runner; older entries
    -- live in `todo_steps`. Free-form jsonb so we can iterate.
    payload         jsonb not null default '{}'::jsonb,

    -- Lifecycle timestamps. `started_at` is the moment Hermes accepted the
    -- run; `updated_at` ticks on every recognized event so the iOS app can
    -- pick a stable refresh id; `completed_at` is set on terminal states.
    started_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    completed_at    timestamptz
);

-- Common lookup: "give me the live activity for this user" used by the
-- list view to attach a row per todo. Kept on (user_id, updated_at) so the
-- realtime fan-out can rank by recency.
create index todo_agent_activity_user_idx
    on todo_agent_activity (user_id, updated_at desc);

create trigger todo_agent_activity_set_updated_at
    before update on todo_agent_activity
    for each row execute function set_updated_at();

-- =========================================================================
-- Row-Level Security
-- =========================================================================
-- Users can only read their own activity rows. Writes are runner-only via
-- the service_role key (no insert/update policy needed for end-users).

alter table todo_agent_activity enable row level security;

create policy "todo_agent_activity_self_select" on todo_agent_activity
    for select using (auth.uid() = user_id);

-- =========================================================================
-- Realtime
-- =========================================================================
-- Same publication every other live-update table joins; the iOS
-- `TodoRealtimeHub` user feed adds a subscription on this table filtered
-- by `user_id=eq.<id>`.

alter publication supabase_realtime add table todo_agent_activity;
