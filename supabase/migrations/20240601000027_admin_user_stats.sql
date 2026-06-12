-- Admin dashboard RPCs (service-role only via Edge Function).
-- REVOKE from public/anon/authenticated; never expose to the iOS client.

-- ---------------------------------------------------------------------------
-- Per-user usage aggregates
-- ---------------------------------------------------------------------------

create or replace function admin_user_stats()
returns table (
    user_id              uuid,
    provisioning_status  text,
    invite_code          text,
    profile_name         text,
    todos_total          bigint,
    todos_done           bigint,
    todos_failed         bigint,
    total_tokens         bigint,
    last_active_at       timestamptz,
    memory_count         bigint,
    cron_count           bigint
)
language sql
security definer
set search_path = public
stable
as $$
    select
        u.user_id,
        up.status::text as provisioning_status,
        up.invite_code,
        uh.profile_name,
        coalesce(t.todos_total, 0) as todos_total,
        coalesce(t.todos_done, 0) as todos_done,
        coalesce(t.todos_failed, 0) as todos_failed,
        coalesce(t.total_tokens, 0) as total_tokens,
        t.last_active_at,
        coalesce(m.memory_count, 0) as memory_count,
        coalesce(c.cron_count, 0) as cron_count
    from (
        select id as user_id from auth.users
    ) u
    left join user_provisioning up on up.user_id = u.user_id
    left join user_hermes uh on uh.user_id = u.user_id
    left join lateral (
        select
            count(*)::bigint as todos_total,
            count(*) filter (where status = 'done')::bigint as todos_done,
            count(*) filter (where status = 'failed')::bigint as todos_failed,
            coalesce(sum(total_tokens), 0)::bigint as total_tokens,
            max(updated_at) as last_active_at
        from todos
        where user_id = u.user_id
    ) t on true
    left join lateral (
        select count(*)::bigint as memory_count
        from memories
        where user_id = u.user_id
          and memory_status = 'active'
    ) m on true
    left join lateral (
        select count(*)::bigint as cron_count
        from cron_jobs
        where user_id = u.user_id
    ) c on true;
$$;

-- ---------------------------------------------------------------------------
-- Invite codes with derived status + redeemer list
-- ---------------------------------------------------------------------------

create or replace function admin_invite_codes()
returns table (
    code        text,
    note        text,
    max_uses    int,
    use_count   int,
    expires_at  timestamptz,
    created_at  timestamptz,
    status      text,
    redeemers   jsonb
)
language sql
security definer
set search_path = public
stable
as $$
    select
        ic.code,
        ic.note,
        ic.max_uses,
        ic.use_count,
        ic.expires_at,
        ic.created_at,
        case
            when ic.expires_at is not null and ic.expires_at < now() then 'expired'
            when ic.use_count = 0 then 'unused'
            when ic.use_count >= ic.max_uses then 'exhausted'
            else 'partial'
        end as status,
        coalesce(
            (
                select jsonb_agg(
                    jsonb_build_object(
                        'user_id', up.user_id,
                        'email', au.email,
                        'provisioning_status', up.status::text,
                        'redeemed_at', up.created_at
                    )
                    order by up.created_at
                )
                from user_provisioning up
                join auth.users au on au.id = up.user_id
                where up.invite_code = ic.code
            ),
            '[]'::jsonb
        ) as redeemers
    from invite_codes ic
    order by ic.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- Dashboard summary counters
-- ---------------------------------------------------------------------------

create or replace function admin_ops_summary()
returns table (
    user_count           bigint,
    provisioned_count    bigint,
    todo_count           bigint,
    total_tokens         bigint,
    pending_provisioning bigint,
    unused_invites       bigint,
    codes_exhausted      bigint
)
language sql
security definer
set search_path = public
stable
as $$
    select
        (select count(*)::bigint from auth.users),
        (select count(*)::bigint from user_hermes),
        (select count(*)::bigint from todos),
        (select coalesce(sum(total_tokens), 0)::bigint from todos),
        (
            select count(*)::bigint
            from user_provisioning
            where status in ('pending', 'provisioning')
        ),
        (
            select count(*)::bigint
            from invite_codes
            where use_count = 0
              and (expires_at is null or expires_at >= now())
        ),
        (
            select count(*)::bigint
            from invite_codes
            where use_count >= max_uses
        );
$$;

revoke all on function admin_user_stats() from public;
revoke all on function admin_invite_codes() from public;
revoke all on function admin_ops_summary() from public;

revoke execute on function admin_user_stats() from anon, authenticated;
revoke execute on function admin_invite_codes() from anon, authenticated;
revoke execute on function admin_ops_summary() from anon, authenticated;
