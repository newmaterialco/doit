-- Provenance + dedupe for todos created by the agent during execution or cron runs.

alter table todos
    add column if not exists spawned_by_todo_id uuid references todos(id) on delete set null,
    add column if not exists spawned_by_cron_job_id uuid references cron_jobs(id) on delete set null,
    add column if not exists spawn_key text;

create unique index if not exists todos_user_spawn_key_uidx
    on todos (user_id, spawn_key)
    where spawn_key is not null;
