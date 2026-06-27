-- Operator-managed entitlement for premium Hermes model access.

create table if not exists premium_model_users (
    user_id    uuid primary key references auth.users(id) on delete cascade,
    note       text,
    created_at timestamptz not null default now()
);

alter table premium_model_users enable row level security;

revoke all on table premium_model_users from public;
grant select, insert, update, delete on table premium_model_users to service_role;
