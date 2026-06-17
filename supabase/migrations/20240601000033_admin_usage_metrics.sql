-- Admin dashboard: DAU/WAU/MAU and daily usage series (service-role only).

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
        union
        select distinct
            t.user_id,
            (t.updated_at at time zone 'utc')::date as day
        from todos t, bounds b
        where (t.updated_at at time zone 'utc')::date between b.start_day and b.today
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
        group by 1
    ),
    daily_created as (
        select
            (t.created_at at time zone 'utc')::date as day,
            count(*)::int as count
        from todos t, bounds b
        where (t.created_at at time zone 'utc')::date between b.start_day and b.today
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
