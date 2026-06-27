-- Exclude operator/test accounts from admin analytics (Overview stats + charts).

create table if not exists admin_analytics_exclusions (
    email      text primary key,
    note       text,
    created_at timestamptz not null default now()
);

alter table admin_analytics_exclusions enable row level security;

insert into admin_analytics_exclusions (email, note)
values ('operator@example.com', 'operator')
on conflict (email) do nothing;

create or replace function admin_analytics_excluded_user_ids()
returns setof uuid
language sql
security definer
set search_path = public
stable
as $$
    select u.id
    from auth.users u
    inner join admin_analytics_exclusions e
        on lower(u.email) = lower(e.email);
$$;

revoke all on function admin_analytics_excluded_user_ids() from public;
grant execute on function admin_analytics_excluded_user_ids() to service_role;
revoke execute on function admin_analytics_excluded_user_ids() from anon, authenticated;

revoke all on table admin_analytics_exclusions from public;
grant select, insert, delete on table admin_analytics_exclusions to service_role;

-- ---------------------------------------------------------------------------
-- Usage metrics (DAU/WAU/MAU + daily charts)
-- ---------------------------------------------------------------------------

create or replace function admin_usage_metrics()
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
    with bounds as (
        select
            (current_timestamp at time zone 'utc')::date as today,
            ((current_timestamp at time zone 'utc')::date - 29) as start_day
    ),
    day_series as (
        select d::date as day
        from bounds b,
        generate_series(b.start_day, b.today, interval '1 day') as d
    ),
    user_activity as (
        select distinct
            t.user_id,
            (t.created_at at time zone 'utc')::date as day
        from todos t, bounds b
        where (t.created_at at time zone 'utc')::date between b.start_day and b.today
          and t.user_id not in (select admin_analytics_excluded_user_ids())
        union
        select distinct
            t.user_id,
            (t.updated_at at time zone 'utc')::date as day
        from todos t, bounds b
        where (t.updated_at at time zone 'utc')::date between b.start_day and b.today
          and t.user_id not in (select admin_analytics_excluded_user_ids())
    ),
    daily_active as (
        select day, count(*)::int as count
        from user_activity
        group by day
    ),
    daily_completed as (
        select
            (coalesce(t.completed_at, t.updated_at) at time zone 'utc')::date as day,
            count(*)::int as count
        from todos t, bounds b
        where t.status = 'done'
          and (coalesce(t.completed_at, t.updated_at) at time zone 'utc')::date
                between b.start_day and b.today
          and t.user_id not in (select admin_analytics_excluded_user_ids())
        group by 1
    ),
    daily_created as (
        select
            (t.created_at at time zone 'utc')::date as day,
            count(*)::int as count
        from todos t, bounds b
        where (t.created_at at time zone 'utc')::date between b.start_day and b.today
          and t.user_id not in (select admin_analytics_excluded_user_ids())
        group by 1
    ),
    headline as (
        select
            (
                select count(distinct ua.user_id)
                from user_activity ua, bounds b
                where ua.day = b.today
            ) as dau,
            (
                select count(distinct ua.user_id)
                from user_activity ua, bounds b
                where ua.day >= b.today - 6
            ) as wau,
            (
                select count(distinct ua.user_id)
                from user_activity ua, bounds b
                where ua.day >= b.start_day
            ) as mau
    )
    select jsonb_build_object(
        'dau', (select dau from headline),
        'wau', (select wau from headline),
        'mau', (select mau from headline),
        'active_users_daily', (
            select coalesce(jsonb_agg(
                jsonb_build_object('day', ds.day, 'count', coalesce(da.count, 0))
                order by ds.day
            ), '[]'::jsonb)
            from day_series ds
            left join daily_active da on da.day = ds.day
        ),
        'tasks_completed_daily', (
            select coalesce(jsonb_agg(
                jsonb_build_object('day', ds.day, 'count', coalesce(dc.count, 0))
                order by ds.day
            ), '[]'::jsonb)
            from day_series ds
            left join daily_completed dc on dc.day = ds.day
        ),
        'tasks_created_daily', (
            select coalesce(jsonb_agg(
                jsonb_build_object('day', ds.day, 'count', coalesce(dcr.count, 0))
                order by ds.day
            ), '[]'::jsonb)
            from day_series ds
            left join daily_created dcr on dcr.day = ds.day
        )
    );
$$;

revoke all on function admin_usage_metrics() from public;
grant execute on function admin_usage_metrics() to service_role;
revoke execute on function admin_usage_metrics() from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Overview summary cards
-- ---------------------------------------------------------------------------

drop function if exists admin_ops_summary();

create or replace function admin_ops_summary()
returns table (
    user_count           bigint,
    provisioned_count    bigint,
    todo_count           bigint,
    total_tokens         bigint,
    pending_provisioning bigint,
    unused_invites       bigint,
    codes_exhausted      bigint,
    feedback_count       bigint,
    feedback_last_7d     bigint
)
language sql
security definer
set search_path = public
stable
as $$
    select
        (
            select count(*)::bigint
            from auth.users u
            where u.id not in (select admin_analytics_excluded_user_ids())
        ),
        (
            select count(*)::bigint
            from user_hermes uh
            where uh.user_id not in (select admin_analytics_excluded_user_ids())
        ),
        (
            select count(*)::bigint
            from todos t
            where t.user_id not in (select admin_analytics_excluded_user_ids())
        ),
        (
            select coalesce(sum(t.total_tokens), 0)::bigint
            from todos t
            where t.user_id not in (select admin_analytics_excluded_user_ids())
        ),
        (
            select count(*)::bigint
            from user_provisioning up
            where up.status in ('pending', 'provisioning')
              and up.user_id not in (select admin_analytics_excluded_user_ids())
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
        ),
        (
            select count(*)::bigint
            from beta_feedback bf
            where bf.user_id not in (select admin_analytics_excluded_user_ids())
        ),
        (
            select count(*)::bigint
            from beta_feedback bf
            where bf.created_at >= now() - interval '7 days'
              and bf.user_id not in (select admin_analytics_excluded_user_ids())
        );
$$;

revoke all on function admin_ops_summary() from public;
grant execute on function admin_ops_summary() to service_role;
revoke execute on function admin_ops_summary() from anon, authenticated;
