-- Structured human-in-the-loop interactions for todos.
--
-- When the agent needs the user to approve, choose, or clarify before
-- continuing, it surfaces a `todo_interactions` row. The todo enters the
-- `needs_input` status so the iOS app can render buttons / draft content
-- inside the todo card and the detail view.
--
-- `todo_steps` remains the append-only activity log. `todo_interactions`
-- holds the small bit of state that the user is expected to act on.

-- =========================================================================
-- Enums
-- =========================================================================

-- New todo status: waiting on a structured user response (not OAuth).
alter type todo_status add value if not exists 'needs_input';

-- New step kind so the runner can log "asked the user for input" in the
-- activity timeline alongside other steps.
alter type step_kind add value if not exists 'input_needed';

create type interaction_kind as enum (
    'approval',       -- "Send this draft?" — has a payload to review
    'choice',         -- "Pick one of these options"
    'question',       -- open question, freeform answer expected
    'confirmation'    -- destructive / irreversible go/no-go
);

create type interaction_status as enum (
    'open',           -- waiting on user
    'responded',      -- user submitted a response; runner may still be resuming
    'cancelled',      -- user (or system) cancelled before responding
    'superseded'      -- replaced by a newer interaction on the same todo
);

-- =========================================================================
-- Table
-- =========================================================================

create table todo_interactions (
    id              uuid primary key default gen_random_uuid(),
    todo_id         uuid not null references todos(id) on delete cascade,
    user_id         uuid not null references auth.users(id) on delete cascade,
    hermes_run_id   text,
    kind            interaction_kind not null,
    status          interaction_status not null default 'open',
    -- Short human-readable prompt. The iOS card renders this as the title.
    prompt          text not null check (char_length(prompt) between 1 and 500),
    -- Optional structured payload the model wants the user to review. Free-form
    -- jsonb so we don't have to migrate the schema every time we add a new
    -- proposal shape. Conventions (not enforced):
    --   { "summary": "...",
    --     "content": { ... },        -- e.g. {"subject":"…","body":"…"} for email
    --     "options": [{"id":"send","label":"Send","style":"primary"}, ...],
    --     "allow_freeform": true,
    --     "freeform_placeholder": "Tell me what to change" }
    payload         jsonb not null default '{}'::jsonb,
    -- User response. Conventions:
    --   { "option_id": "send", "text": "…optional freeform…" }
    response        jsonb,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    responded_at    timestamptz
);

create index todo_interactions_todo_id_idx
    on todo_interactions (todo_id, created_at desc);
create index todo_interactions_open_idx
    on todo_interactions (todo_id) where status = 'open';

create trigger todo_interactions_set_updated_at
    before update on todo_interactions
    for each row execute function set_updated_at();

-- =========================================================================
-- Row-Level Security
-- =========================================================================
-- Users can read their own interactions and update only the response /
-- status fields on their own *open* row. The runner uses service_role for
-- inserts and for marking rows superseded/cancelled.

alter table todo_interactions enable row level security;

create policy "todo_interactions_self_select" on todo_interactions
    for select using (auth.uid() = user_id);

-- Users can only flip an open interaction into a terminal state by writing
-- response/status. The check clause keeps user-driven updates scoped: they
-- can't reassign the row to another todo/user, and they can't reopen a
-- closed interaction.
create policy "todo_interactions_self_respond" on todo_interactions
    for update
    using (auth.uid() = user_id and status = 'open')
    with check (
        auth.uid() = user_id
        and status in ('responded', 'cancelled')
    );

-- =========================================================================
-- Realtime
-- =========================================================================

alter publication supabase_realtime add table todo_interactions;
