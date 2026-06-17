-- Admin dashboard: operational issues feed (service-role only via Edge Function).

-- Extend task list with failure message for operator debugging.
drop function if exists admin_todos_list(int, int, text, text, uuid, text);

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
    error_message       text,
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
            coalesce(t.total_tokens, 0)::bigint as total_tokens,
            t.error_message
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
        f.error_message,
        count(*) over ()::bigint as total_count
    from filtered f
    order by f.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ---------------------------------------------------------------------------
-- Issue counts for dashboard summary cards
-- ---------------------------------------------------------------------------

create or replace function admin_issues_summary()
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
    with counts as (
        select
            (
                select count(*)::int
                from todos t
                where t.status = 'failed'
            ) as failed_task,
            (
                select count(*)::int
                from todos t
                where t.status = 'running'
                  and (
                      t.run_claimed_at is null
                      or t.run_claimed_at < now() - interval '10 minutes'
                  )
            ) as stuck_running,
            (
                select count(*)::int
                from todos t
                where t.status = 'preparing'
                  and (
                      t.prep_claimed_at is null
                      or t.prep_claimed_at < now() - interval '10 minutes'
                  )
            ) as stuck_preparing,
            (
                select count(*)::int
                from user_provisioning up
                where up.status = 'failed'
            ) as failed_provision,
            (
                select count(*)::int
                from user_provisioning up
                where up.status in ('pending', 'provisioning')
                  and up.created_at < now() - interval '10 minutes'
            ) as stuck_provision,
            (
                select count(*)::int
                from memories m
                where m.sync_status = 'failed'
            ) as memory_sync_failed,
            (
                select count(*)::int
                from cron_jobs cj
                where cj.state = 'running'
                  and (
                      cj.run_claimed_at is null
                      or cj.run_claimed_at < now() - interval '10 minutes'
                  )
            ) as stuck_cron
    )
    select jsonb_build_object(
        'failed_task', c.failed_task,
        'stuck_running', c.stuck_running,
        'stuck_preparing', c.stuck_preparing,
        'failed_provision', c.failed_provision,
        'stuck_provision', c.stuck_provision,
        'memory_sync_failed', c.memory_sync_failed,
        'stuck_cron', c.stuck_cron,
        'total',
            c.failed_task + c.stuck_running + c.stuck_preparing
            + c.failed_provision + c.stuck_provision
            + c.memory_sync_failed + c.stuck_cron
    )
    from counts c;
$$;

-- ---------------------------------------------------------------------------
-- Paginated issues feed
-- ---------------------------------------------------------------------------

create or replace function admin_issues_list(
    p_limit  int  default 50,
    p_offset int  default 0,
    p_kind   text default null
)
returns table (
    kind           text,
    severity       text,
    occurred_at    timestamptz,
    user_id        uuid,
    user_email     text,
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
            t.user_id,
            au.email as user_email,
            coalesce(nullif(trim(coalesce(t.original_title, t.title)), ''), 'Task') as summary,
            coalesce(nullif(trim(t.error_message), ''), 'Task failed') as detail,
            t.id as reference_id,
            'todo'::text as reference_type
        from todos t
        join auth.users au on au.id = t.user_id
        where t.status = 'failed'

        union all

        select
            'stuck_running',
            'warn',
            coalesce(t.run_claimed_at, t.updated_at, t.created_at),
            t.user_id,
            au.email,
            coalesce(nullif(trim(coalesce(t.original_title, t.title)), ''), 'Task'),
            'Running past lease (>10 min)',
            t.id,
            'todo'
        from todos t
        join auth.users au on au.id = t.user_id
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
            t.user_id,
            au.email,
            coalesce(nullif(trim(coalesce(t.original_title, t.title)), ''), 'Task'),
            'Preparing past lease (>10 min)',
            t.id,
            'todo'
        from todos t
        join auth.users au on au.id = t.user_id
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
            up.user_id,
            au.email,
            'Provisioning',
            coalesce(nullif(trim(up.error), ''), 'Provisioning failed'),
            up.user_id,
            'user'
        from user_provisioning up
        join auth.users au on au.id = up.user_id
        where up.status = 'failed'

        union all

        select
            'stuck_provision',
            'warn',
            coalesce(up.updated_at, up.created_at),
            up.user_id,
            au.email,
            'Provisioning',
            'Pending/provisioning >10 min (status: ' || up.status::text || ')',
            up.user_id,
            'user'
        from user_provisioning up
        join auth.users au on au.id = up.user_id
        where up.status in ('pending', 'provisioning')
          and up.created_at < now() - interval '10 minutes'

        union all

        select
            'memory_sync_failed',
            'error',
            coalesce(m.updated_at, m.created_at),
            m.user_id,
            au.email,
            coalesce(nullif(trim(m.title), ''), 'Memory sync'),
            coalesce(nullif(trim(m.sync_error), ''), 'Memory sync failed'),
            m.id,
            'memory'
        from memories m
        join auth.users au on au.id = m.user_id
        where m.sync_status = 'failed'

        union all

        select
            'stuck_cron',
            'warn',
            coalesce(cj.run_claimed_at, cj.updated_at, cj.created_at),
            cj.user_id,
            au.email,
            coalesce(nullif(trim(cj.name), ''), 'Cron job'),
            'Cron running past lease (>10 min)',
            cj.id,
            'cron_job'
        from cron_jobs cj
        join auth.users au on au.id = cj.user_id
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
        f.user_id,
        f.user_email,
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

revoke all on function admin_todos_list(int, int, text, text, uuid, text) from public;
grant execute on function admin_todos_list(int, int, text, text, uuid, text) to service_role;
revoke execute on function admin_todos_list(int, int, text, text, uuid, text) from anon, authenticated;

revoke all on function admin_issues_summary() from public;
grant execute on function admin_issues_summary() to service_role;
revoke execute on function admin_issues_summary() from anon, authenticated;

revoke all on function admin_issues_list(int, int, text) from public;
grant execute on function admin_issues_list(int, int, text) to service_role;
revoke execute on function admin_issues_list(int, int, text) from anon, authenticated;
