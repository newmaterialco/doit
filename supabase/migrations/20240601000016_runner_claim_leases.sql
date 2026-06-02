-- Short runner leases for work types whose visible status should not change
-- while they are being processed. Prevents duplicate prep/config execution
-- when multiple runner processes overlap, while still allowing retry after a
-- stale claim.

alter table todos
    add column if not exists prep_claimed_at timestamptz;

create index if not exists todos_preparing_claim_idx
    on todos (created_at)
    where status = 'preparing';

create index if not exists todos_spawned_by_todo_title_idx
    on todos (user_id, spawned_by_todo_id, title)
    where spawned_by_todo_id is not null;

create index if not exists todos_spawned_by_cron_title_idx
    on todos (user_id, spawned_by_cron_job_id, title)
    where spawned_by_cron_job_id is not null;

alter table cron_jobs
    add column if not exists configure_claimed_at timestamptz;

create index if not exists cron_jobs_configuring_claim_idx
    on cron_jobs (updated_at)
    where state = 'configuring';
