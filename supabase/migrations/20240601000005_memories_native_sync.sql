-- Mirror Hermes' native MEMORY.md / USER.md into the app so Settings > Memory
-- can show what the agent has actually learned, and let the user pin facts
-- that the runner will write into the matching Hermes file before the next
-- run.
--
-- New columns on `memories`:
--   target            which Hermes file this entry mirrors ('user' | 'memory')
--   source            whether the entry was authored by the user or curated
--                     by Hermes itself ('user' | 'hermes')
--   sync_status       state of the next sync into Hermes ('pending' | 'synced' | 'failed')
--   hermes_fingerprint  stable hash of the on-disk entry text (set once the
--                     entry exists in Hermes' files); used to dedupe both
--                     directions of the sync
--   last_sync_at      when the entry last reached Hermes successfully
--   sync_error        last sync error, if any (cleared on success)
--
-- User-authored entries start with source='user' and sync_status='pending'.
-- Hermes-curated entries are inserted by the runner with source='hermes' and
-- sync_status='synced'. The fingerprint is what we match against
-- USER.md/MEMORY.md, so two rows can never collide on the same on-disk text.

alter table memories
    add column target text not null default 'user'
        check (target in ('user', 'memory')),
    add column source text not null default 'user'
        check (source in ('user', 'hermes')),
    add column sync_status text not null default 'pending'
        check (sync_status in ('pending', 'synced', 'failed')),
    add column hermes_fingerprint text,
    add column last_sync_at timestamptz,
    add column sync_error text;

-- One row per (user, target, fingerprint). Lets the runner upsert mirrored
-- Hermes entries idempotently without colliding with the user's pinned rows.
create unique index memories_user_target_fingerprint_idx
    on memories (user_id, target, hermes_fingerprint)
    where hermes_fingerprint is not null;

-- Surfacing pending sync work efficiently per user.
create index memories_user_pending_sync_idx
    on memories (user_id, sync_status)
    where sync_status = 'pending';

comment on column memories.target is
    'Which Hermes memory file this entry mirrors: user -> USER.md, memory -> MEMORY.md.';
comment on column memories.source is
    'Who authored the entry: user (typed in the app) or hermes (curated by the agent).';
comment on column memories.sync_status is
    'pending = needs to be written into the Hermes file before the next run; '
    'synced = present in the matching Hermes file; failed = last write failed.';
comment on column memories.hermes_fingerprint is
    'Stable hash of the on-disk entry text. NULL until the entry has been '
    'written into Hermes; used as the join key for mirroring.';
