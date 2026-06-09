-- Doit-owned memory lifecycle.
--
-- Built-in Hermes memory is a delivery mechanism for the model, but the app
-- needs a user-visible source of truth. These columns let Doit show suggested
-- memories in Passbook, activate approved/high-confidence memories, and remove
-- deleted memories from Hermes on the next source-of-truth rewrite.

alter table memories
    add column memory_status text not null default 'active'
        check (memory_status in ('proposed', 'active', 'rejected', 'deleted')),
    add column memory_confidence text
        check (memory_confidence is null or memory_confidence in ('high', 'medium', 'low')),
    add column memory_reason text check (
        memory_reason is null or char_length(memory_reason) <= 500
    ),
    add column source_todo_id uuid references todos(id) on delete set null,
    add column reviewed_at timestamptz;

-- The extractor is Doit-authored, distinct from user pins and direct Hermes
-- memory-tool writes.
alter table memories drop constraint if exists memories_source_check;
alter table memories
    add constraint memories_source_check
    check (source in ('user', 'hermes', 'doit'));

create index memories_user_status_updated_at_idx
    on memories (user_id, memory_status, updated_at desc);

create index memories_source_todo_id_idx
    on memories (source_todo_id)
    where source_todo_id is not null;

comment on column memories.memory_status is
    'proposed = suggested for review; active = projected into Hermes; '
    'rejected/deleted = not projected into Hermes.';
comment on column memories.memory_confidence is
    'Extractor confidence for Doit-authored suggestions.';
comment on column memories.memory_reason is
    'Short explanation for why Doit proposed this memory.';
comment on column memories.source_todo_id is
    'Todo whose transcript produced this memory candidate.';

alter publication supabase_realtime add table memories;

create table memory_settings (
    user_id uuid primary key references auth.users(id) on delete cascade,
    automatic_suggestions_enabled boolean not null default true,
    custom_instructions text check (
        custom_instructions is null or char_length(custom_instructions) <= 1000
    ),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create trigger memory_settings_set_updated_at
    before update on memory_settings
    for each row execute function set_updated_at();

alter table memory_settings enable row level security;

create policy "memory_settings_self_select" on memory_settings
    for select using (auth.uid() = user_id);

create policy "memory_settings_self_insert" on memory_settings
    for insert with check (auth.uid() = user_id);

create policy "memory_settings_self_update" on memory_settings
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);


