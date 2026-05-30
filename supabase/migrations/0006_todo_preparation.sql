-- Preparation phase for todos.
--
-- When a user creates a new todo it enters `preparing` instead of `todo` so
-- the runner can:
--   1. Rephrase the user's raw input into a concise title.
--   2. Pick a likely Composio connection (toolkit slug) for the icon.
--   3. Ask any clarification questions before the agent ever takes action.
--
-- Only after preparation finishes does the todo land in `todo` (ready) and
-- wait for the user to tap "Do it" to flip it to `requested` for execution.
-- Clarifications happen through the existing `todo_interactions` mechanism;
-- the runner distinguishes preparation interactions from execution ones via
-- `payload.phase = 'prepare'`.

-- =========================================================================
-- Enums
-- =========================================================================

-- New todo status: agent is preparing/enriching the task (not executing).
alter type todo_status add value if not exists 'preparing';

-- =========================================================================
-- Columns on todos
-- =========================================================================

alter table todos
    add column if not exists original_title text,
    add column if not exists connection_slug text
        check (connection_slug is null
               or char_length(connection_slug) between 1 and 64),
    add column if not exists preparation_summary text
        check (preparation_summary is null
               or char_length(preparation_summary) between 1 and 500);

comment on column todos.original_title is
    'The raw text the user typed when creating the todo, preserved before '
    'the preparation phase rewrites `title` into a concise version.';
comment on column todos.connection_slug is
    'Composio toolkit slug (e.g. gmail, googlecalendar) the agent expects to '
    'use, surfaced as the connection icon on the todo card. NULL when no '
    'external connection is needed or the agent could not pick one.';
comment on column todos.preparation_summary is
    'Short human-readable summary of what the agent plans to do, written '
    'during the preparation phase.';

-- Note: a partial index `where status = 'preparing'` would be nice for the
-- runner's claim query, but Postgres forbids referencing a newly-added
-- enum value in the same transaction (SQLSTATE 55P04). If the preparing
-- queue grows large enough to matter, add that index in a follow-up
-- migration so it runs after this ALTER TYPE has committed.
