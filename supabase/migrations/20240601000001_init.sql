-- doit schema: todos, todo_steps, devices, user_hermes
-- All tables are RLS-scoped to auth.uid().
-- The runner uses the service_role key (bypasses RLS) to write across users.

-- =========================================================================
-- Enums
-- =========================================================================

create type todo_status as enum (
    'todo',         -- created, not yet handed to the agent
    'requested',    -- user tapped "Do it" — picked up by the runner
    'running',      -- agent is working on it
    'needs_auth',   -- waiting on the user to connect an account
    'done',
    'failed',
    'cancelled'
);

create type step_kind as enum (
    'thought',
    'tool_started',
    'tool_result',
    'oauth_needed',
    'final',
    'error'
);

-- =========================================================================
-- Tables
-- =========================================================================

-- Per-user mapping to the Hermes profile running on the VM.
-- Populated by an admin (you) when onboarding a friend; not user-writable.
create table user_hermes (
    user_id        uuid primary key references auth.users(id) on delete cascade,
    profile_name   text not null,
    api_host       text not null default '127.0.0.1',
    api_port       int  not null,
    api_key        text not null,
    composio_entity text not null,  -- per-user Composio entity (=user_id by convention)
    created_at     timestamptz not null default now()
);

create table todos (
    id                uuid primary key default gen_random_uuid(),
    user_id           uuid not null references auth.users(id) on delete cascade,
    title             text not null check (char_length(title) between 1 and 500),
    detail            text,
    status            todo_status not null default 'todo',
    hermes_run_id     text,        -- /v1/runs/{id} that's working on this
    hermes_session_id text,
    error_message     text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),
    completed_at      timestamptz
);

create index todos_user_id_idx on todos (user_id, created_at desc);
create index todos_status_idx  on todos (status) where status in ('requested', 'running');

create table todo_steps (
    id        bigserial primary key,
    todo_id   uuid not null references todos(id) on delete cascade,
    user_id   uuid not null references auth.users(id) on delete cascade,
    ts        timestamptz not null default now(),
    kind      step_kind not null,
    text      text,
    -- For oauth_needed steps: the URL the app should open via ASWebAuthenticationSession.
    url       text,
    -- For tool_started/tool_result: which tool fired (e.g. "send_email", "web_search").
    tool_name text
);

create index todo_steps_todo_id_idx on todo_steps (todo_id, ts);

create table devices (
    user_id    uuid not null references auth.users(id) on delete cascade,
    apns_token text not null,
    updated_at timestamptz not null default now(),
    primary key (user_id, apns_token)
);

-- =========================================================================
-- updated_at trigger on todos
-- =========================================================================

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger todos_set_updated_at
    before update on todos
    for each row execute function set_updated_at();

-- =========================================================================
-- Row-Level Security
-- =========================================================================

alter table user_hermes enable row level security;
alter table todos       enable row level security;
alter table todo_steps  enable row level security;
alter table devices     enable row level security;

-- user_hermes: users can read their own row only (write is service_role only)
create policy "user_hermes_self_read" on user_hermes
    for select using (auth.uid() = user_id);

-- todos: full CRUD on own rows
create policy "todos_self_select" on todos
    for select using (auth.uid() = user_id);
create policy "todos_self_insert" on todos
    for insert with check (auth.uid() = user_id);
create policy "todos_self_update" on todos
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "todos_self_delete" on todos
    for delete using (auth.uid() = user_id);

-- todo_steps: read-only for users (the runner writes via service_role)
create policy "todo_steps_self_select" on todo_steps
    for select using (auth.uid() = user_id);

-- devices: full CRUD on own rows
create policy "devices_self_select" on devices
    for select using (auth.uid() = user_id);
create policy "devices_self_insert" on devices
    for insert with check (auth.uid() = user_id);
create policy "devices_self_update" on devices
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "devices_self_delete" on devices
    for delete using (auth.uid() = user_id);

-- =========================================================================
-- Realtime
-- =========================================================================
-- Add tables to the supabase_realtime publication so the iOS app gets live
-- updates on its own rows (RLS still applies to subscriptions).

alter publication supabase_realtime add table todos;
alter publication supabase_realtime add table todo_steps;
