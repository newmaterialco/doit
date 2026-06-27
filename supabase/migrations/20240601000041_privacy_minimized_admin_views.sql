-- Privacy-minimized admin views.
--
-- Routine operator tooling should show operational state without exposing task
-- content or joining task rows to user emails. Hosted execution still processes
-- task plaintext, but admin views should not casually surface it.

drop function if exists admin_todos_list(int, int, text, text, uuid, text);
drop function if exists admin_todos_list(int, int, text, text, text);
drop function if exists admin_issues_list(int, int, text);

create or replace function admin_privacy_user_label(p_user_id uuid)
returns text
language sql
immutable
as $$
    select 'User ' || upper(substr(replace(p_user_id::text, '-', ''), 1, 8));
$$;

revoke all on function admin_privacy_user_label(uuid) from public;
grant execute on function admin_privacy_user_label(uuid) to service_role;
revoke execute on function admin_privacy_user_label(uuid) from anon, authenticated;

create or replace function admin_safe_error_category(p_error text)
returns text
language sql
immutable
as $$
    select case
        when p_error is null or trim(p_error) = '' then null
        when p_error ilike '%timeout%' then 'timeout'
        when p_error ilike '%rate limit%' or p_error ilike '%429%' then 'rate_limited'
        when p_error ilike '%auth%' or p_error ilike '%permission%' then 'auth_or_permission'
        when p_error ilike '%cancel%' then 'cancelled'
        else 'task_failed'
    end;
$$;

revoke all on function admin_safe_error_category(text) from public;
grant execute on function admin_safe_error_category(text) to service_role;
revoke execute on function admin_safe_error_category(text) from anon, authenticated;

create or replace function admin_todos_list(
    p_limit           int  default 50,
    p_offset          int  default 0,
    p_search          text default null,
    p_status          text default null,
    p_connection_slug text default null
)
returns table (
    id                  uuid,
    user_label          text,
    created_at          timestamptz,
    updated_at          timestamptz,
    status              text,
    connection_slug     text,
    total_tokens        bigint,
    error_category      text,
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
            admin_privacy_user_label(t.user_id) as user_label,
            t.created_at,
            t.updated_at,
            t.status::text as status,
            t.connection_slug,
            coalesce(t.total_tokens, 0)::bigint as total_tokens,
            admin_safe_error_category(t.error_message) as error_category
        from todos t
        where
            (p_status is null or t.status::text = p_status)
            and (p_connection_slug is null or t.connection_slug = p_connection_slug)
            and (
                p_search is null
                or trim(p_search) = ''
                or t.id::text ilike '%' || trim(p_search) || '%'
                or admin_privacy_user_label(t.user_id) ilike '%' || trim(p_search) || '%'
                or t.connection_slug ilike '%' || trim(p_search) || '%'
            )
    )
    select
        f.id,
        f.user_label,
        f.created_at,
        f.updated_at,
        f.status,
        f.connection_slug,
        f.total_tokens,
        f.error_category,
        count(*) over ()::bigint as total_count
    from filtered f
    order by f.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

create or replace function admin_issues_list(
    p_limit  int  default 50,
    p_offset int  default 0,
    p_kind   text default null
)
returns table (
    kind           text,
    severity       text,
    occurred_at    timestamptz,
    user_label     text,
    summary        text,
    detail         text,
    reference_id   uuid,
    reference_type text,
    total_count    bigint
)
language sql
security definer
set search_path = public
stable
as $$
    with issues as (
        select
            'failed_task'::text as kind,
            'error'::text as severity,
            coalesce(t.updated_at, t.created_at) as occurred_at,
            admin_privacy_user_label(t.user_id) as user_label,
            'Task failed'::text as summary,
            coalesce(admin_safe_error_category(t.error_message), 'task_failed') as detail,
            t.id as reference_id,
            'todo'::text as reference_type
        from todos t
        where t.status = 'failed'

        union all

        select
            'stuck_running',
            'warn',
            coalesce(t.run_claimed_at, t.updated_at, t.created_at),
            admin_privacy_user_label(t.user_id),
            'Task running past lease',
            'Running past lease (>10 min)',
            t.id,
            'todo'
        from todos t
        where t.status = 'running'
          and (
              t.run_claimed_at is null
              or t.run_claimed_at < now() - interval '10 minutes'
          )

        union all

        select
            'stuck_preparing',
            'warn',
            coalesce(t.prep_claimed_at, t.updated_at, t.created_at),
            admin_privacy_user_label(t.user_id),
            'Task preparing past lease',
            'Preparing past lease (>10 min)',
            t.id,
            'todo'
        from todos t
        where t.status = 'preparing'
          and (
              t.prep_claimed_at is null
              or t.prep_claimed_at < now() - interval '10 minutes'
          )

        union all

        select
            'failed_provision',
            'error',
            coalesce(up.updated_at, up.created_at),
            admin_privacy_user_label(up.user_id),
            'Provisioning failed',
            'Provisioning failed',
            up.user_id,
            'user'
        from user_provisioning up
        where up.status = 'failed'

        union all

        select
            'stuck_provision',
            'warn',
            coalesce(up.updated_at, up.created_at),
            admin_privacy_user_label(up.user_id),
            'Provisioning stuck',
            'Pending/provisioning >10 min',
            up.user_id,
            'user'
        from user_provisioning up
        where up.status in ('pending', 'provisioning')
          and up.created_at < now() - interval '10 minutes'

        union all

        select
            'memory_sync_failed',
            'error',
            coalesce(m.updated_at, m.created_at),
            admin_privacy_user_label(m.user_id),
            'Memory sync failed',
            'Memory sync failed',
            m.id,
            'memory'
        from memories m
        where m.sync_status = 'failed'

        union all

        select
            'stuck_cron',
            'warn',
            coalesce(cj.run_claimed_at, cj.updated_at, cj.created_at),
            admin_privacy_user_label(cj.user_id),
            'Cron job running past lease',
            'Cron running past lease (>10 min)',
            cj.id,
            'cron_job'
        from cron_jobs cj
        where cj.state = 'running'
          and (
              cj.run_claimed_at is null
              or cj.run_claimed_at < now() - interval '10 minutes'
          )
    ),
    filtered as (
        select *
        from issues i
        where
            p_kind is null
            or trim(p_kind) = ''
            or i.kind = trim(p_kind)
    )
    select
        f.kind,
        f.severity,
        f.occurred_at,
        f.user_label,
        f.summary,
        f.detail,
        f.reference_id,
        f.reference_type,
        count(*) over ()::bigint as total_count
    from filtered f
    order by
        case f.severity when 'error' then 0 else 1 end,
        f.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function admin_todos_list(int, int, text, text, text) from public;
grant execute on function admin_todos_list(int, int, text, text, text) to service_role;
revoke execute on function admin_todos_list(int, int, text, text, text) from anon, authenticated;

revoke all on function admin_issues_list(int, int, text) from public;
grant execute on function admin_issues_list(int, int, text) to service_role;
revoke execute on function admin_issues_list(int, int, text) from anon, authenticated;
