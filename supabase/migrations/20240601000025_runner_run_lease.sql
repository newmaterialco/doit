-- Execution leases for the concurrent runner.
--
-- `prep_claimed_at` (20240601000016) already protects the preparation pass.
-- This adds the same protection to execution: a todo claimed into `running`
-- now records `run_claimed_at`, and the runner heartbeats that column while
-- the run is in flight. If the runner crashes mid-run the lease goes stale
-- and a later claim recovers the todo instead of stranding it in `running`
-- forever.
--
-- Cron jobs get the same column for the equivalent stuck-`running` recovery.

alter table todos
    add column if not exists run_claimed_at timestamptz;

-- Claim scans for recoverable runs: status = 'running' with a stale lease.
create index if not exists todos_running_claim_idx
    on todos (created_at)
    where status = 'running';

alter table cron_jobs
    add column if not exists run_claimed_at timestamptz;

create index if not exists cron_jobs_running_claim_idx
    on cron_jobs (next_run_at)
    where state = 'running';
