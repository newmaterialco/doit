-- Beta user feedback submitted from Settings in the iOS app.
-- Writes go through the feedback Edge Function (service_role only).

create table if not exists beta_feedback (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    message text not null check (char_length(trim(message)) >= 1),
    include_email boolean not null default false,
    contact_email text,
    app_version text,
    ios_version text,
    device_model text,
    created_at timestamptz not null default now()
);

create index if not exists beta_feedback_created_at_idx on beta_feedback (created_at desc);
create index if not exists beta_feedback_user_id_idx on beta_feedback (user_id);

alter table beta_feedback enable row level security;

-- Extend admin dashboard summary with feedback counts.
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
        ),
        (select count(*)::bigint from beta_feedback),
        (
            select count(*)::bigint
            from beta_feedback
            where created_at >= now() - interval '7 days'
        );
$$;

revoke all on function admin_ops_summary() from public;
grant execute on function admin_ops_summary() to service_role;

revoke execute on function admin_ops_summary() from anon, authenticated;
