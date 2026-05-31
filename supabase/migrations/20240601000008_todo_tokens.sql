-- Lifetime token counter per todo.
--
-- Hermes' /v1/runs/{id} returns `usage: { input_tokens, output_tokens,
-- total_tokens }` on terminal state, and per-turn `response.completed`
-- events on the SSE stream carry the same `usage` shape mid-run. The
-- runner accumulates these into `total_tokens` so iOS can show a live,
-- animating cost counter on the detail view's drag pill.
--
-- This is a running lifetime total — re-runs and retries on the same
-- todo add to the same column rather than resetting it.

alter table todos
    add column total_tokens bigint not null default 0;

-- Atomic increment so concurrent runners (in theory only one per todo,
-- but cheap insurance) and the runner's interleaved SSE updates can't
-- clobber each other with read-modify-write.
create or replace function increment_todo_tokens(
    p_todo_id uuid,
    p_delta   bigint
)
returns void
language sql
security definer
set search_path = public
as $$
    update todos
       set total_tokens = total_tokens + greatest(p_delta, 0),
           updated_at   = now()
     where id = p_todo_id;
$$;

grant execute on function increment_todo_tokens(uuid, bigint) to service_role;
