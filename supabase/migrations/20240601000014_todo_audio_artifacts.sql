-- Audio artifacts (spoken summaries) for todos.
--
-- When a Hermes run produces a long-form deliverable that benefits from a
-- spoken summary (digest, recap, briefing), the agent calls its built-in
-- `text_to_speech` tool. The runner intercepts that tool's output, uploads
-- the generated audio file to the private `todo-audio` Supabase Storage
-- bucket, and records it as a new `audio` artifact alongside any other
-- deliverables.
--
-- The iOS detail header renders the audio artifact as a compact AVPlayer
-- card (play/pause, scrubber, duration) with the long-form written summary
-- underneath, so the user can either listen or read.
--
-- Payload conventions (free-form jsonb; not enforced by the schema):
--   audio -> { "bucket": "todo-audio",
--              "storage_path": "<user>/<todo>/<uuid>.mp3",
--              "mime_type": "audio/mpeg" | "audio/ogg",
--              "provider": "elevenlabs" | "openai" | "edge" | ...,
--              "voice_id": "...",                  -- optional
--              "duration_seconds": 42.7,           -- optional
--              "text": "Long-form written summary that mirrors the spoken
--                       version and renders under the player." }
--
-- Keep this in sync with:
--   * `_ARTIFACT_KINDS` in runner/runner/events.py
--   * `ArtifactKind` in ios/doit/doit/Models/TodoArtifact.swift

-- =========================================================================
-- Storage bucket for generated audio
-- =========================================================================
-- Mirrors the per-user folder layout used by `todo-attachments` so the same
-- RLS shape works: objects live at `<user_id>/<todo_id>/<uuid>.<ext>` and
-- a user can only read/write their own folder. The runner uses the
-- service_role key to upload across users.

insert into storage.buckets (id, name, public)
values ('todo-audio', 'todo-audio', false)
on conflict (id) do nothing;

create policy "todo_audio_self_select" on storage.objects
    for select using (
        bucket_id = 'todo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_audio_self_insert" on storage.objects
    for insert with check (
        bucket_id = 'todo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_audio_self_update" on storage.objects
    for update using (
        bucket_id = 'todo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "todo_audio_self_delete" on storage.objects
    for delete using (
        bucket_id = 'todo-audio'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

-- =========================================================================
-- Extend todo_artifacts.kind to include `audio`
-- =========================================================================
-- The original CHECK in 20240601000009_todo_artifacts.sql only allowed
-- ('link', 'email', 'calendar', 'text'). Drop and recreate it with `audio`
-- added so the existing parse_artifacts + upsert path can persist audio
-- rows without changing column shape.

alter table todo_artifacts
    drop constraint if exists todo_artifacts_kind_check;

alter table todo_artifacts
    add constraint todo_artifacts_kind_check
    check (kind in ('link', 'email', 'calendar', 'text', 'audio'));
