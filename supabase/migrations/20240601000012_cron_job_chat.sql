-- Chat + clarifications for scheduled cron jobs (mirrors todo_messages /
-- todo_interactions so the detail view can reuse the same chat UX).

alter type cron_job_state add value if not exists 'needs_input';
alter type cron_job_state add value if not exists 'configuring';

alter table cron_jobs
    add column if not exists original_prompt text,
    add column if not exists configuration_summary text;

create table cron_job_messages (
    id           uuid primary key default gen_random_uuid(),
    cron_job_id  uuid not null references cron_jobs(id) on delete cascade,
    user_id      uuid not null references auth.users(id) on delete cascade,
    body         text not null check (char_length(body) between 1 and 4000),
    consumed_at  timestamptz,
    created_at   timestamptz not null default now()
);

create index cron_job_messages_job_id_idx
    on cron_job_messages (cron_job_id, created_at);
create index cron_job_messages_unconsumed_idx
    on cron_job_messages (cron_job_id) where consumed_at is null;

create table cron_job_interactions (
    id              uuid primary key default gen_random_uuid(),
    cron_job_id     uuid not null references cron_jobs(id) on delete cascade,
    user_id         uuid not null references auth.users(id) on delete cascade,
    hermes_run_id   text,
    kind            interaction_kind not null,
    status          interaction_status not null default 'open',
    prompt          text not null check (char_length(prompt) between 1 and 500),
    payload         jsonb not null default '{}'::jsonb,
    response        jsonb,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    responded_at    timestamptz
);

create index cron_job_interactions_job_id_idx
    on cron_job_interactions (cron_job_id, created_at desc);
create index cron_job_interactions_open_idx
    on cron_job_interactions (cron_job_id) where status = 'open';

create trigger cron_job_interactions_set_updated_at
    before update on cron_job_interactions
    for each row execute function set_updated_at();

alter table cron_job_messages enable row level security;
alter table cron_job_interactions enable row level security;

create policy "cron_job_messages_self_select" on cron_job_messages
    for select using (auth.uid() = user_id);
create policy "cron_job_messages_self_insert" on cron_job_messages
    for insert with check (auth.uid() = user_id);

create policy "cron_job_interactions_self_select" on cron_job_interactions
    for select using (auth.uid() = user_id);
create policy "cron_job_interactions_self_respond" on cron_job_interactions
    for update
    using (auth.uid() = user_id and status = 'open')
    with check (
        auth.uid() = user_id
        and status in ('responded', 'cancelled')
    );

alter publication supabase_realtime add table cron_job_messages;
alter publication supabase_realtime add table cron_job_interactions;
