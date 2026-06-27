-- BYO Hermes connector pairing and heartbeat state.

create table if not exists byo_connectors (
    user_id              uuid primary key references auth.users(id) on delete cascade,
    pairing_code_hash    text not null,
    connector_token_hash text not null,
    status               text not null default 'pairing'
        check (status in ('pairing', 'online', 'offline', 'revoked')),
    profile_name         text,
    endpoint_url         text,
    capabilities         jsonb not null default '{}'::jsonb,
    last_heartbeat_at    timestamptz,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

create index if not exists byo_connectors_token_hash_idx
    on byo_connectors (connector_token_hash);

drop trigger if exists byo_connectors_set_updated_at on byo_connectors;
create trigger byo_connectors_set_updated_at
    before update on byo_connectors
    for each row execute function set_updated_at();

alter table byo_connectors enable row level security;

drop policy if exists "byo_connectors_self_select" on byo_connectors;
create policy "byo_connectors_self_select" on byo_connectors
    for select using (auth.uid() = user_id);

revoke all on table byo_connectors from public;
grant select on table byo_connectors to authenticated;
grant select, insert, update, delete on table byo_connectors to service_role;

create or replace function connector_scoped_user_id(p_token_hash text)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
    select user_id
    from byo_connectors
    where connector_token_hash = p_token_hash
      and status <> 'revoked'
    limit 1;
$$;

revoke all on function connector_scoped_user_id(text) from public;
grant execute on function connector_scoped_user_id(text) to service_role;
revoke execute on function connector_scoped_user_id(text) from anon, authenticated;
