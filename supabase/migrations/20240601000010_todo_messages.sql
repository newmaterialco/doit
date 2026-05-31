-- Free-form chat messages from the user to the agent, per todo.
--
-- Until now the only way a user could send text mid-task was the structured
-- `todo_interactions` card (typed answer to a model-posed question). This
-- table backs the live chat composer in the detail view: any time the user
-- wants to talk back to Hermes about an in-flight or finished task, the iOS
-- app inserts a row here and flips the todo to `requested` so the runner
-- resumes the same Hermes session with the message woven into the prompt.
--
-- `todo_steps` stays runner-only (no user insert policy); this is the
-- user-writable counterpart. The runner stamps `consumed_at` once a
-- message has been folded into a prompt so the next resume doesn't
-- replay it.

create table todo_messages (
    id           uuid primary key default gen_random_uuid(),
    todo_id      uuid not null references todos(id) on delete cascade,
    user_id      uuid not null references auth.users(id) on delete cascade,
    body         text not null check (char_length(body) between 1 and 4000),
    -- Set by the runner (service_role) when this message is included in a
    -- Hermes prompt. Unconsumed rows are picked up on the next claim.
    consumed_at  timestamptz,
    created_at   timestamptz not null default now()
);

create index todo_messages_todo_id_idx
    on todo_messages (todo_id, created_at);
create index todo_messages_unconsumed_idx
    on todo_messages (todo_id) where consumed_at is null;

-- =========================================================================
-- Row-Level Security
-- =========================================================================
-- Users can read and append messages on their own todos. The runner uses
-- service_role to stamp `consumed_at`; users never update or delete rows
-- so the chat history is append-only from their side.

alter table todo_messages enable row level security;

create policy "todo_messages_self_select" on todo_messages
    for select using (auth.uid() = user_id);

create policy "todo_messages_self_insert" on todo_messages
    for insert with check (auth.uid() = user_id);

-- =========================================================================
-- Realtime
-- =========================================================================

alter publication supabase_realtime add table todo_messages;
