-- Persist the user's local timezone for wall-clock cron schedules so a
-- "Daily at 9 AM" job created in California fires at 9 AM Pacific forever
-- rather than 9 AM UTC. The timezone is captured once at creation time and
-- never auto-follows the device after that — travel does not silently shift
-- a recurring automation.
--
-- Rows with timezone = NULL keep the legacy UTC evaluation. Existing cron
-- jobs created before this migration therefore keep their current behavior
-- until the user edits or reconfigures them.

alter table cron_jobs
    add column if not exists timezone text
        check (timezone is null or char_length(timezone) between 1 and 64);

comment on column cron_jobs.timezone is
    'IANA timezone (e.g. America/Los_Angeles) used to evaluate wall-clock '
    'cron expressions for this job. NULL means evaluate in UTC (legacy).';

-- Snapshot of the client's IANA timezone at todo creation. The runner reads
-- this when promoting a recurring todo into a cron_jobs row so the new job
-- inherits the location the user was in when they typed the schedule.
alter table todos
    add column if not exists client_timezone text
        check (client_timezone is null or char_length(client_timezone) between 1 and 64);

comment on column todos.client_timezone is
    'IANA timezone reported by the client when this todo was created. Used '
    'by the runner to set cron_jobs.timezone for newly-promoted recurring '
    'automations. Has no effect on one-shot tasks.';
