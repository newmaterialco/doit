-- Invite list: filter by email_sent operator flag.

drop function if exists admin_invite_codes_list(int, int, text, text, text);

create or replace function admin_invite_codes_list(
    p_limit       int  default 50,
    p_offset      int  default 0,
    p_status      text default null,
    p_sort        text default null,
    p_search      text default null,
    p_email_sent  text default null
)
returns table (
    code         text,
    note         text,
    max_uses     int,
    use_count    int,
    expires_at   timestamptz,
    created_at   timestamptz,
    last_used_at timestamptz,
    email_sent   boolean,
    status       text,
    redeemers    jsonb,
    total_count  bigint
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
            ic.email_sent,
            (
                select max(up.created_at)
                from user_provisioning up
                where up.invite_code = ic.code
            ) as last_used_at,
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
            (
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
            and (
                p_email_sent is null
                or trim(p_email_sent) = ''
                or lower(trim(p_email_sent)) = 'all'
                or (lower(trim(p_email_sent)) in ('sent', 'yes', 'true') and ic.email_sent = true)
                or (lower(trim(p_email_sent)) in ('not_sent', 'no', 'false') and ic.email_sent = false)
            )
            and (
                p_search is null
                or trim(p_search) = ''
                or ic.code ilike '%' || trim(p_search) || '%'
                or coalesce(ic.note, '') ilike '%' || trim(p_search) || '%'
            )
    )
    select
        f.code,
        f.note,
        f.max_uses,
        f.use_count,
        f.expires_at,
        f.created_at,
        f.last_used_at,
        f.email_sent,
        f.status,
        f.redeemers,
        count(*) over ()::bigint as total_count
    from filtered f
    order by
        case
            when lower(trim(coalesce(p_sort, 'created_desc'))) = 'created_asc'
                then f.created_at
        end asc nulls last,
        case
            when lower(trim(coalesce(p_sort, 'created_desc'))) in ('used', 'used_desc')
                then f.last_used_at
        end desc nulls last,
        case
            when lower(trim(coalesce(p_sort, ''))) = 'used_asc'
                then f.last_used_at
        end asc nulls last,
        f.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function admin_invite_codes_list(int, int, text, text, text, text) from public;
grant execute on function admin_invite_codes_list(int, int, text, text, text, text) to service_role;
revoke execute on function admin_invite_codes_list(int, int, text, text, text, text) from anon, authenticated;
