-- Admin dashboard: paginated, filterable task list (service-role only via Edge Function).

create or replace function admin_todos_list(
    p_limit           int  default 50,
    p_offset          int  default 0,
    p_search          text default null,
    p_status          text default null,
    p_user_id         uuid default null,
    p_connection_slug text default null
)
returns table (
    id                  uuid,
    user_id             uuid,
    user_email          text,
    created_at          timestamptz,
    updated_at          timestamptz,
    status              text,
    original_title      text,
    title               text,
    preparation_summary text,
    connection_slug     text,
    total_tokens        bigint,
    total_count         bigint
)
language sql
security definer
set search_path = public
stable
as $$
    with filtered as (
        select
            t.id,
            t.user_id,
            au.email as user_email,
            t.created_at,
            t.updated_at,
            t.status::text as status,
            t.original_title,
            t.title,
            t.preparation_summary,
            t.connection_slug,
            coalesce(t.total_tokens, 0)::bigint as total_tokens
        from todos t
        join auth.users au on au.id = t.user_id
        where
            (p_user_id is null or t.user_id = p_user_id)
            and (p_status is null or t.status::text = p_status)
            and (p_connection_slug is null or t.connection_slug = p_connection_slug)
            and (
                p_search is null
                or trim(p_search) = ''
                or coalesce(t.original_title, t.title) ilike '%' || trim(p_search) || '%'
                or t.preparation_summary ilike '%' || trim(p_search) || '%'
            )
    )
    select
        f.id,
        f.user_id,
        f.user_email,
        f.created_at,
        f.updated_at,
        f.status,
        f.original_title,
        f.title,
        f.preparation_summary,
        f.connection_slug,
        f.total_tokens,
        count(*) over ()::bigint as total_count
    from filtered f
    order by f.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function admin_todos_list(int, int, text, text, uuid, text) from public;
grant execute on function admin_todos_list(int, int, text, text, uuid, text) to service_role;

revoke execute on function admin_todos_list(int, int, text, text, uuid, text) from anon, authenticated;
