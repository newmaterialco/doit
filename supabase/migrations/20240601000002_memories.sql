-- User-visible agent memories.
--
-- Hermes built-in memory is profile-local on the VM. This table gives the app
-- a secure, auditable memory surface that the runner can pass to Hermes.

create table memories (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    title       text not null check (char_length(title) between 1 and 120),
    body        text not null check (char_length(body) between 1 and 2000),
    category    text check (category is null or char_length(category) between 1 and 80),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index memories_user_id_updated_at_idx on memories (user_id, updated_at desc);

create trigger memories_set_updated_at
    before update on memories
    for each row execute function set_updated_at();

alter table memories enable row level security;

create policy "memories_self_select" on memories
    for select using (auth.uid() = user_id);
create policy "memories_self_insert" on memories
    for insert with check (auth.uid() = user_id);
create policy "memories_self_update" on memories
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "memories_self_delete" on memories
    for delete using (auth.uid() = user_id);
