-- Generated marble thumbnails for Passbook-visible memories.
--
-- The runner generates a small display image via OpenAI, uploads it to the
-- private `memory-images` bucket at `<user_id>/<memory_id>.png`, and stores
-- the path on the memory row. iOS signs the path on demand for Passbook rows.

alter table memories
    add column image_storage_path text,
    add column image_status text not null default 'pending'
        check (image_status in ('pending', 'ready', 'failed', 'skipped')),
    add column image_content_hash text,
    add column image_error text check (
        image_error is null or char_length(image_error) <= 500
    );

-- Existing rows should not mass-generate on deploy.
update memories
set image_status = 'skipped'
where image_status = 'pending';

create index memories_pending_image_idx
    on memories (image_status, updated_at desc)
    where image_status = 'pending';

comment on column memories.image_storage_path is
    'Relative path in the memory-images bucket (<user_id>/<memory_id>.png).';
comment on column memories.image_status is
    'pending = awaiting runner generation; ready = stored image available; '
    'failed = last generation attempt failed; skipped = pre-existing or ineligible.';
comment on column memories.image_content_hash is
    'Hash of title+body used to decide whether an edit needs regeneration.';
comment on column memories.image_error is
    'Short last image-generation error for debugging.';

insert into storage.buckets (id, name, public)
values ('memory-images', 'memory-images', false)
on conflict (id) do nothing;

create policy "memory_images_self_select" on storage.objects
    for select using (
        bucket_id = 'memory-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "memory_images_self_insert" on storage.objects
    for insert with check (
        bucket_id = 'memory-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "memory_images_self_update" on storage.objects
    for update using (
        bucket_id = 'memory-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "memory_images_self_delete" on storage.objects
    for delete using (
        bucket_id = 'memory-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );
