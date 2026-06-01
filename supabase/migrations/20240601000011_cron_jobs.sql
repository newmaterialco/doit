-- Scheduled (recurring) agent tasks surfaced in the iOS "Scheduled" dock tab.
-- The runner ticks due jobs and runs them through Hermes in fresh sessions.

create type cron_job_state as enum (
    'scheduled',   -- active, will fire at next_run_at
    'paused',      -- suspended until resumed
    'running',     -- transient while the runner executes
    'completed'    -- one-shot jobs that have fired
);

create table cron_jobs (
    id                uuid primary key default gen_random_uuid(),
    user_id           uuid not null references auth.users(id) on delete cascade,
    name              text not null check (char_length(name) between 1 and 200),
    prompt            text not null check (char_length(prompt) between 1 and 4000),
    schedule          text not null check (char_length(schedule) between 1 and 120),
    schedule_display  text,
    connection_slug   text,
    state             cron_job_state not null default 'scheduled',
    enabled           boolean not null default true,
    next_run_at       timestamptz,
    last_run_at       timestamptz,
    last_status       text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

create index cron_jobs_user_id_idx on cron_jobs (user_id, created_at desc);
create index cron_jobs_due_idx on cron_jobs (next_run_at)
    where enabled = true and state = 'scheduled';

create trigger cron_jobs_set_updated_at
    before update on cron_jobs
    for each row execute function set_updated_at();

alter table cron_jobs enable row level security;

create policy "cron_jobs_self_select" on cron_jobs
    for select using (auth.uid() = user_id);
create policy "cron_jobs_self_insert" on cron_jobs
    for insert with check (auth.uid() = user_id);
create policy "cron_jobs_self_update" on cron_jobs
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "cron_jobs_self_delete" on cron_jobs
    for delete using (auth.uid() = user_id);

alter publication supabase_realtime add table cron_jobs;
