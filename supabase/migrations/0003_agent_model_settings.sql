-- User-selectable Hermes model settings.
--
-- The app can read the non-secret settings row through RLS. Provider API keys
-- are global Doit server secrets configured on the VM runner, not user input.

create type agent_model_provider as enum (
    'openai',
    'anthropic'
);

create type agent_model_apply_status as enum (
    'pending',
    'applied',
    'failed'
);

create table agent_model_settings (
    user_id          uuid primary key references auth.users(id) on delete cascade,
    provider         agent_model_provider not null,
    model            text not null,
    apply_status     agent_model_apply_status not null default 'pending',
    apply_error      text,
    last_applied_at  timestamptz,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);

create trigger agent_model_settings_set_updated_at
    before update on agent_model_settings
    for each row execute function set_updated_at();

alter table agent_model_settings enable row level security;

create policy "agent_model_settings_self_select" on agent_model_settings
    for select using (auth.uid() = user_id);
