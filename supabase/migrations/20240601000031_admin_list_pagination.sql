-- Admin dashboard: paginated list RPCs (service-role only via Edge Function).

-- ---------------------------------------------------------------------------
-- Paginated user list with stats
-- ---------------------------------------------------------------------------

create or replace function admin_users_list(
    p_limit  int default 50,
    p_offset int default 0
)
returns table (
    user_id              uuid,
    email                text,
    signed_up_at         timestamptz,
    provisioning_status  text,
    invite_code          text,
    profile_name         text,
    todos_total          bigint,
    todos_done           bigint,
    todos_failed         bigint,
    total_tokens         bigint,
    last_active_at       timestamptz,
    total_count          bigint
)
language sql
security definer
set search_path = public
stable
as $$
    with base as (
        select
            au.id as user_id,
            au.email,
            au.created_at as signed_up_at,
            up.status::text as provisioning_status,
            up.invite_code,
            uh.profile_name,
            coalesce(t.todos_total, 0)::bigint as todos_total,
            coalesce(t.todos_done, 0)::bigint as todos_done,
            coalesce(t.todos_failed, 0)::bigint as todos_failed,
            coalesce(t.total_tokens, 0)::bigint as total_tokens,
            t.last_active_at
        from auth.users au
        left join user_provisioning up on up.user_id = au.id
        left join user_hermes uh on uh.user_id = au.id
        left join lateral (
            select
                count(*)::bigint as todos_total,
                count(*) filter (where status = 'done')::bigint as todos_done,
                count(*) filter (where status = 'failed')::bigint as todos_failed,
                coalesce(sum(total_tokens), 0)::bigint as total_tokens,
                max(updated_at) as last_active_at
            from todos
            where user_id = au.id
        ) t on true
    )
    select
        b.user_id,
        b.email,
        b.signed_up_at,
        b.provisioning_status,
        b.invite_code,
        b.profile_name,
        b.todos_total,
        b.todos_done,
        b.todos_failed,
        b.total_tokens,
        b.last_active_at,
        count(*) over ()::bigint as total_count
    from base b
    order by b.signed_up_at desc nulls last
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ---------------------------------------------------------------------------
-- Lightweight user id + email for Tasks filter dropdown
-- ---------------------------------------------------------------------------

create or replace function admin_user_options()
returns table (
    user_id uuid,
    email   text
)
language sql
security definer
set search_path = public
stable
as $$
    select au.id as user_id, au.email
    from auth.users au
    order by coalesce(au.email, au.id::text);
$$;

-- ---------------------------------------------------------------------------
-- Paginated beta feedback
-- ---------------------------------------------------------------------------

create or replace function admin_feedback_list(
    p_limit  int default 50,
    p_offset int default 0
)
returns table (
    id             uuid,
    user_id        uuid,
    message        text,
    include_email  boolean,
    contact_email  text,
    app_version    text,
    ios_version    text,
    device_model   text,
    created_at     timestamptz,
    total_count    bigint
)
language sql
security definer
set search_path = public
stable
as $$
    select
        bf.id,
        bf.user_id,
        bf.message,
        bf.include_email,
        bf.contact_email,
        bf.app_version,
        bf.ios_version,
        bf.device_model,
        bf.created_at,
        count(*) over ()::bigint as total_count
    from beta_feedback bf
    order by bf.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ---------------------------------------------------------------------------
-- Paginated invite codes with status filter
-- ---------------------------------------------------------------------------

create or replace function admin_invite_codes_list(
    p_limit   int  default 50,
    p_offset  int  default 0,
    p_status  text default null
)
returns table (
    code        text,
    note        text,
    max_uses    int,
    use_count   int,
    expires_at  timestamptz,
    created_at  timestamptz,
    status      text,
    redeemers   jsonb,
    total_count bigint
)
language sql
security definer
set search_path = public
stable
as $$
    with filtered as (
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
        where
            p_status is null
            or trim(p_status) = ''
            or lower(trim(p_status)) = 'all'
            or (
                lower(trim(p_status)) = 'unused'
                and ic.use_count = 0
                and (ic.expires_at is null or ic.expires_at >= now())
            )
            or (lower(trim(p_status)) = 'used' and ic.use_count > 0)
    )
    select
        f.code,
        f.note,
        f.max_uses,
        f.use_count,
        f.expires_at,
        f.created_at,
        f.status,
        f.redeemers,
        count(*) over ()::bigint as total_count
    from filtered f
    order by f.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function admin_users_list(int, int) from public;
revoke all on function admin_user_options() from public;
revoke all on function admin_feedback_list(int, int) from public;
revoke all on function admin_invite_codes_list(int, int, text) from public;

grant execute on function admin_users_list(int, int) to service_role;
grant execute on function admin_user_options() to service_role;
grant execute on function admin_feedback_list(int, int) to service_role;
grant execute on function admin_invite_codes_list(int, int, text) to service_role;

revoke execute on function admin_users_list(int, int) from anon, authenticated;
revoke execute on function admin_user_options() from anon, authenticated;
revoke execute on function admin_feedback_list(int, int) from anon, authenticated;
revoke execute on function admin_invite_codes_list(int, int, text) from anon, authenticated;
