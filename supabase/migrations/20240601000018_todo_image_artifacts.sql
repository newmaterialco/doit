-- Image artifacts for todos.
--
-- When a Hermes run produces a visual deliverable (Figma export, generated
-- mockup, browser screenshot, chart, diagram) the agent emits a structured
-- `image` artifact. The runner downloads/reads the image, uploads it to the
-- private `todo-images` Supabase Storage bucket, and records the durable
-- storage path on the artifact row. The iOS detail view renders it as an
-- inline image card.
--
-- Payload conventions (free-form jsonb; not enforced by the schema):
--   image -> { "bucket": "todo-images",
--              "storage_path": "<user>/<todo>/<uuid>.<ext>",
--              "mime_type": "image/png" | "image/jpeg" | "image/webp" | "image/svg+xml",
--              "provider": "figma" | "openai" | "browser" | ...,   -- optional
--              "width": 390,                                          -- optional
--              "height": 844,                                         -- optional
--              "prompt": "source prompt or describe the image",      -- optional
--              "source_url": "https://..." }                          -- optional
--
-- Keep this in sync with:
--   * `_ARTIFACT_KINDS` in runner/runner/events.py
--   * `ArtifactKind` in ios/doit/doit/Models/TodoArtifact.swift

-- =========================================================================
-- Storage bucket for generated/exported images
-- =========================================================================
-- Mirrors the per-user folder layout used by `todo-audio` and
-- `todo-attachments` so the same RLS shape works: objects live at
-- `<user_id>/<todo_id>/<uuid>.<ext>` and a user can only read/write their
-- own folder. The runner uses the service_role key to upload across users.

insert into storage.buckets (id, name, public)
values ('todo-images', 'todo-images', false)
on conflict (id) do nothing;

create policy "todo_images_self_select" on storage.objects
    for select using (
        bucket_id = 'todo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_images_self_insert" on storage.objects
    for insert with check (
        bucket_id = 'todo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_images_self_update" on storage.objects
    for update using (
        bucket_id = 'todo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_images_self_delete" on storage.objects
    for delete using (
        bucket_id = 'todo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

-- =========================================================================
-- Extend todo_artifacts.kind to include `image`
-- =========================================================================
-- Drops and recreates the CHECK so existing parse_artifacts + upsert can
-- persist image rows without changing column shape.

alter table todo_artifacts
    drop constraint if exists todo_artifacts_kind_check;

alter table todo_artifacts
    add constraint todo_artifacts_kind_check
    check (kind in ('link', 'email', 'calendar', 'text', 'audio', 'image'));
