-- Invite-gated automated agent provisioning.
--
-- Flow: the iOS onboarding screen calls the `onboarding` Edge Function,
-- which redeems an invite code via the atomic RPC below and inserts a
-- `pending` row into user_provisioning. The provisioner loop inside the
-- runner polls for pending rows, builds the Hermes profile + Composio
-- session + systemd unit on the VM, upserts user_hermes, and flips the
-- row to `ready`. The app watches the row over Realtime.

-- ---------------------------------------------------------------------------
-- 1. Invite codes (operator-minted, service-role only)
-- ---------------------------------------------------------------------------

create table invite_codes (
    code        text primary key check (char_length(code) between 4 and 64),
    max_uses    int not null default 1 check (max_uses > 0),
    use_count   int not null default 0 check (use_count >= 0),
    expires_at  timestamptz,
    note        text,
    created_at  timestamptz not null default now()
);

-- RLS on with no policies: clients can never read or redeem codes directly.
-- Redemption goes through the security-definer RPC below, called with the
-- service-role key from the onboarding Edge Function.
alter table invite_codes enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Per-user provisioning state
-- ---------------------------------------------------------------------------

create type provisioning_status as enum (
    'pending',       -- invite redeemed, waiting for the provisioner
    'provisioning',  -- provisioner is building the agent right now
    'ready',         -- user_hermes row exists; agent is usable
    'failed'         -- provisioning errored; safe to retry
);

create table user_provisioning (
    user_id      uuid primary key references auth.users(id) on delete cascade,
    status       provisioning_status not null default 'pending',
    error        text,
    invite_code  text references invite_codes(code),
    -- Lease stamp while status='provisioning' so a crashed provisioner's
    -- claim goes stale and the row gets retried (same pattern as todo
    -- claims).
    claimed_at   timestamptz,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

create index user_provisioning_pending_idx
    on user_provisioning (created_at)
    where status in ('pending', 'provisioning');

create trigger user_provisioning_set_updated_at
    before update on user_provisioning
    for each row execute function set_updated_at();

alter table user_provisioning enable row level security;

-- Users may read their own row (the onboarding screen subscribes to it);
-- all writes go through service-role (Edge Function + runner).
create policy "user_provisioning_self_select" on user_provisioning
    for select using (auth.uid() = user_id);

-- Live status updates for the "Creating your agent..." screen.
alter publication supabase_realtime add table user_provisioning;

-- ---------------------------------------------------------------------------
-- 3. Atomic invite redemption (called by the onboarding Edge Function)
-- ---------------------------------------------------------------------------

create or replace function redeem_invite_code(p_code text, p_user_id uuid)
returns table (ok boolean, reason text, status text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_existing user_provisioning%rowtype;
    v_updated  int;
begin
    -- Idempotent: a user who already redeemed (any status) does not consume
    -- another use. A `failed` row flips back to `pending` so the iOS retry
    -- button can re-queue provisioning without a fresh code.
    select * into v_existing from user_provisioning where user_id = p_user_id;
    if found then
        if v_existing.status = 'failed' then
            update user_provisioning
               set status = 'pending', error = null, claimed_at = null
             where user_id = p_user_id;
            return query select true, 'retry'::text, 'pending'::text;
            return;
        end if;
        return query select true, 'already_redeemed'::text, v_existing.status::text;
        return;
    end if;

    -- Users provisioned manually before this system existed: backfill a
    -- ready row so they never see the invite screen.
    if exists (select 1 from user_hermes where user_id = p_user_id) then
        insert into user_provisioning (user_id, status)
        values (p_user_id, 'ready')
        on conflict (user_id) do nothing;
        return query select true, 'already_provisioned'::text, 'ready'::text;
        return;
    end if;

    -- Validate + consume in one statement so concurrent redemptions of the
    -- last use can't both succeed.
    update invite_codes
       set use_count = use_count + 1
     where code = p_code
       and use_count < max_uses
       and (expires_at is null or expires_at > now());
    get diagnostics v_updated = row_count;
    if v_updated = 0 then
        return query select false, 'invalid_code'::text, null::text;
        return;
    end if;

    insert into user_provisioning (user_id, status, invite_code)
    values (p_user_id, 'pending', p_code);
    return query select true, 'redeemed'::text, 'pending'::text;
end;
$$;

-- Service-role only; never callable with a user JWT.
revoke execute on function redeem_invite_code(text, uuid) from public;
revoke execute on function redeem_invite_code(text, uuid) from anon;
revoke execute on function redeem_invite_code(text, uuid) from authenticated;

-- ---------------------------------------------------------------------------
-- 4. Port allocation safety + backfill for existing users
-- ---------------------------------------------------------------------------

-- Two gateways can never share host:port. The provisioner allocates
-- max(api_port)+1 and relies on this constraint (with retry) under races.
alter table user_hermes
    add constraint user_hermes_host_port_key unique (api_host, api_port);

-- Existing manually-onboarded users are already provisioned.
insert into user_provisioning (user_id, status)
select user_id, 'ready'::provisioning_status from user_hermes
on conflict (user_id) do nothing;
