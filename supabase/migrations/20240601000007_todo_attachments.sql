-- Image attachments for todos.
--
-- Users can attach photos (camera or gallery) when creating a task or from
-- the detail view of an existing task. The bytes live in a private Supabase
-- Storage bucket scoped per-user; this table is the relational index the
-- iOS app and runner use to discover them.
--
-- The runner generates short-lived signed URLs at prompt-build time and
-- inlines them in the agent's text input so Hermes' built-in
-- `vision_analyze` tool can fetch the pixels on demand.

-- =========================================================================
-- Storage bucket
-- =========================================================================

insert into storage.buckets (id, name, public)
values ('todo-attachments', 'todo-attachments', false)
on conflict (id) do nothing;

-- Storage RLS: a user can only touch objects under a top-level folder named
-- after their auth.uid(). The iOS app uploads to `<user_id>/<todo_id>/<uuid>.jpg`.
create policy "todo_attachments_self_select" on storage.objects
    for select using (
        bucket_id = 'todo-attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_attachments_self_insert" on storage.objects
    for insert with check (
        bucket_id = 'todo-attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_attachments_self_update" on storage.objects
    for update using (
        bucket_id = 'todo-attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_attachments_self_delete" on storage.objects
    for delete using (
        bucket_id = 'todo-attachments'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

-- =========================================================================
-- Table
-- =========================================================================

create table todo_attachments (
    id           uuid primary key default gen_random_uuid(),
    todo_id      uuid not null references todos(id) on delete cascade,
    user_id      uuid not null references auth.users(id) on delete cascade,
    -- Path inside the todo-attachments bucket, e.g. `<user>/<todo>/<uuid>.jpg`.
    storage_path text not null check (char_length(storage_path) between 1 and 1024),
    mime_type    text not null check (char_length(mime_type) between 1 and 100),
    width        int  check (width is null or width > 0),
    height       int  check (height is null or height > 0),
    created_at   timestamptz not null default now()
);

create index todo_attachments_todo_id_idx
    on todo_attachments (todo_id, created_at);

-- =========================================================================
-- Row-Level Security
-- =========================================================================
-- Users have full CRUD on their own attachment rows. The runner uses
-- service_role to read across users when building agent prompts.

alter table todo_attachments enable row level security;

create policy "todo_attachments_self_select" on todo_attachments
    for select using (auth.uid() = user_id);

create policy "todo_attachments_self_insert" on todo_attachments
    for insert with check (auth.uid() = user_id);

create policy "todo_attachments_self_update" on todo_attachments
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "todo_attachments_self_delete" on todo_attachments
    for delete using (auth.uid() = user_id);

-- =========================================================================
-- Realtime
-- =========================================================================

alter publication supabase_realtime add table todo_attachments;
