# Task realtime contract (iOS ↔ Supabase ↔ runner)

How a task ends up rendering live on the phone after the agent does work. If
you change any of the pieces below, read this whole file first — every line
here exists because a previous change broke "the list doesn't update until I
open the task".

## Single source of truth

```
runner (service_role) ──► Postgres rows ──► Supabase Realtime
                                                    │
                                                    ▼
                                     TodoRealtimeHub (user feed)
                                                    │
                                                    ▼
                                         TodoStore (@Observable)
                                                    │
                                                    ▼
                                TodoListView  /  TodoDetailView
                                          (observers, no caches)
```

The store in [`ios/doit/doit/Stores/TodoStore.swift`](../ios/doit/doit/Stores/TodoStore.swift)
owns:

- `todos` — every row, ordered by `created_at` desc (matches `TodosAPI.list()`)
- `cronJobs` — every cron job row
- `openInteractions[todoID]` — the latest `open` `todo_interactions` row per todo
- `artifactsByTodoID[todoID]` — agent-produced deliverables per todo
- `interactionsByTodoID[todoID]` — full history, populated on demand by detail
  views via `beginTracking(todoID:)`

Views read from the store and call its methods to mutate. They MUST NOT keep
their own `@State` copies of any of the above. This is the rule that keeps
breaking; if you find yourself adding `@State private var todos: [Todo]` you
are about to reintroduce the bug.

## Why a store and not view-local state

The list and the detail view both watch the same rows. When they each kept
their own `@State` copies:

- The list pulled rows via `TodosAPI.list()`; the detail view pulled the
  same row via a separate select.
- The list refreshed via a "something changed" callback that reloaded
  everything; the detail view had its own per-todo subscriptions.
- A missed realtime event on the list channel left the list stale until the
  user opened the task, at which point the detail view's independent fetch
  populated its own copy. The list still looked wrong because nothing told
  the list to refresh that specific row.

With a shared store, the realtime hub patches one row in one place and every
view that reads from the store re-renders automatically.

## The realtime hub

[`ios/doit/doit/Supabase/TodoRealtimeHub.swift`](../ios/doit/doit/Supabase/TodoRealtimeHub.swift)
keeps two long-lived feed types.

### User feed (`startUserFeed(userID:handlers:)`)

Started by `TodoStore.start(userID:)` and torn down by `TodoStore.stop()`.
Subscribes to four tables, all filtered by `user_id=eq.<userID>`:

| Table               | Row id extracted from | Store callback                   |
| ------------------- | --------------------- | -------------------------------- |
| `todos`             | `record.id` / `oldRecord.id` | `refreshTodo(id:)` / `removeTodoLocal(id:)` |
| `todo_interactions` | `record.todo_id`      | `refreshOpenInteraction(for:)` + `refreshInteractions(for:)` if tracked |
| `todo_artifacts`    | `record.todo_id`      | `refreshArtifacts(for:)`         |
| `todo_agent_activity` | `record.todo_id`    | `refreshAgentActivity(for:)` / removes from `agentActivityByTodoID` |
| `cron_jobs`         | `record.id`           | `refreshCronJob(id:)` / `removeCronJobLocal(id:)` |

On each change the hub extracts the id from the realtime payload and the
store fetches the single row via the typed REST API. We deliberately do
**not** decode the realtime payload directly: the REST round-trip lets us
keep custom date decoders, RLS, and column-default rules in exactly one
place (`TodosAPI` / `CronJobsAPI`).

If the payload doesn't carry a usable id the hub calls `onUnknown` which
runs `store.loadAll()` as a fallback. This should be rare.

### Detail feeds (`beginTodoWatch`, `beginCronJobWatch`)

Each detail view starts a small per-row feed for the chat-only tables that
the user feed doesn't carry:

- `TodoDetailView`: `todo_steps` + `todo_messages`
- `CronJobDetailView`: `cron_job_messages` + `cron_job_interactions`

The task row, the open interaction, and artifacts already flow through the
user feed → store, so the detail view reads them from the store instead of
maintaining a parallel subscription.

`endTodoWatch()` / `endCronJobWatch()` are called by the list when
`navigationPath.count == 0` so the channels live across the navigation push
itself (avoid wiring them into `onAppear` / `onDisappear` — that fires
during the push transition and was previously cancelling in-flight
`subscribeWithError()` calls).

## What the runner writes

When Hermes finishes:

1. **Prep pass** (`runner/runner/runner.py::prepare_one_todo`):
   - Updates `todos` with `title`, `connection_slug`, `preparation_summary`
     and flips `status` from `preparing` → `todo`.
   - If the agent needs a clarification, inserts a `todo_interactions` row
     with `payload.phase = "prepare"` and flips `status` to `needs_input`.
   - If the prep result is a cron, deletes the todo and inserts a
     `cron_jobs` row.
2. **Execution pass** (`runner/runner/runner.py::_consume_run`):
   - Per SSE event, writes `todo_steps`, upserts `todo_artifacts`,
     increments `todos.total_tokens`, and upserts the current-activity
     snapshot into `todo_agent_activity` via `AgentActivityService` (see
     [agent activity service](#agent-activity-service-live-what-is-hermes-doing)
     below).
   - On terminal events: updates `todos.status`, may insert
     `todo_interactions`, writes a terminal `todo_agent_activity`
     snapshot (so iOS shows the closing card instead of stale "working
     on…" copy), sends APNs.

Every one of these writes goes through `service_role`, which means RLS is
bypassed on the runner side but the realtime publication still fires for
each row change. The iOS app sees the change via the user feed.

Realtime is configured in the migrations under `supabase/migrations/`. The
relevant `alter publication supabase_realtime add table ...` statements live
in:

- `20240601000001_init.sql`  (`todos`, `todo_steps`)
- `20240601000004_todo_interactions.sql`
- `20240601000009_todo_artifacts.sql`
- `20240601000010_todo_messages.sql`
- `20240601000011_cron_jobs.sql`
- `20240601000012_cron_job_chat.sql`
- `20240601000015_todo_agent_activity.sql`

If you add a new table that the iOS app needs to watch live, add it to the
realtime publication AND extend the store + hub. Don't try to poll from a
view.

## Agent activity service (live "what is Hermes doing")

`todo_steps` is the historical audit log. The runner *also* maintains a
single live snapshot of what Hermes is doing right now in the
`todo_agent_activity` table — one row per todo, replaced on every relevant
SSE event. The iOS app uses that snapshot to drive three surfaces from one
contract:

| Surface                  | Lives in                                                                                                       | Reads                                  |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Todo list card subtitle  | [`TodoListView.swift`](../ios/doit/doit/Views/TodoListView.swift)`/TodoCard.statusText`                          | `store.agentActivityByTodoID[todo.id]` |
| Detail-header activity card | [`TaskHeaderView.swift`](../ios/doit/doit/Views/TodoChat/TaskHeaderView.swift) + [`AgentActivityCard.swift`](../ios/doit/doit/Views/AgentActivity/AgentActivityCard.swift) | `store.agentActivity(for: todoID)`     |
| Live Activity widget     | [`AgentLiveActivityManager.swift`](../ios/doit/doit/Stores/AgentLiveActivityManager.swift) + [`doitActivityWidget`](../ios/doit/doitActivityWidget/) | observes `TodoStore.agentActivityByTodoID` |

### Data flow

```
Hermes SSE  ──► events.translate ──► AgentActivityService
                                          │
                                          ▼
                              upsert_agent_activity()
                                          │
                                          ▼
                          todo_agent_activity (Postgres row)
                                          │
                                          ▼
                              Supabase Realtime publication
                                          │
                                          ▼
                       TodoRealtimeHub → TodoStore.refreshAgentActivity
                                          │
                                          ▼
            (agentActivityByTodoID.didSet → syncLiveActivities)
                                          │
                ┌─────────────────────────┼─────────────────────────┐
                ▼                         ▼                         ▼
        TodoCard.statusText      AgentActivityCard          AgentLiveActivityManager
        (single shimmer line)    (header animated card)     (Lock Screen + Dynamic Island)
```

### Snapshot contract

`todo_agent_activity` columns and the iOS [`AgentActivity`](../ios/doit/doit/Models/AgentActivity.swift)
struct mirror each other 1:1. Important fields:

- `phase` (`starting` | `tool` | `tool_done` | `thinking` | `needs_auth` |
  `needs_input` | `final` | `failed` | `cancelled`).
- `state` (`running` | `paused` | `completed` | `failed` | `cancelled`).
  Drives icons, color, and Live Activity lifecycle (`completed`/`failed`/
  `cancelled` end the activity).
- `title` (≤ 200 chars) — the one-line shimmer copy ("Searching Gmail",
  "Reviewing Gmail results"). The card subtitle, the detail card shimmer,
  and the Live Activity current intent all read from this.
- `detail` (≤ 400 chars, optional) — sanitized one-line context shown
  under the title in the detail card and Live Activity expanded layout.
  Never raw chain-of-thought; the runner clips to the first line.
- `tool_name` / `tool_category` — drive SF Symbol selection
  (`AgentToolCategory.symbolName`).
- `payload.steps` — the most recent 8 steps (oldest dropped). Each step
  is `{ id, kind, title, detail?, tool_name?, tool_category?, started_at,
  completed_at? }`. The detail card uses these for the "stacked
  previous-intent" pile.
- `hermes_run_id` — handy for debugging only; the iOS app does not query
  it directly.
- `started_at` / `updated_at` / `completed_at` — used for elapsed-time
  labels and Live Activity timers.

### Rules

1. **Snapshot, not history.** `todo_agent_activity` has exactly one row
   per `todo_id`. The runner upserts on `(todo_id)`; never insert new
   rows. Use `todo_steps` for history.
2. **Terminal snapshots are required.** Every code path that exits a run
   (success, failure, cancellation, OAuth needed, input needed, timeout,
   exception) must write a final snapshot. Otherwise the card sits on
   "Working on…" forever and the Live Activity never ends. See the
   `_write_activity` calls in
   [`runner/runner.py`](../runner/runner/runner.py).
3. **Sanitize titles and details on the runner side.** Trim, clip, and
   strip interaction markers (`[[DOIT_INTERACTION]]`) before persisting.
   The iOS app trusts that what it gets is safe to render.
4. **Live Activity lifecycle belongs in `AgentLiveActivityManager`.**
   Views must never call `Activity.request` / `Activity.update` /
   `activity.end` directly. The manager observes the store and handles
   start, debounced update, and end. Navigating away from a detail view
   must not kill a running Lock Screen activity.
5. **One contract, three surfaces.** Do not add a fourth source of
   "what is the agent doing?" copy. If a new surface needs that data,
   read `TodoStore.agentActivity(for:)`; don't introduce a parallel
   computation. Likewise, do not derive activity text from
   `todo_steps` on the client — that's what this snapshot exists to
   avoid.
6. **Chowder is a UI reference only.** The widget styling
   ([`HermesLiveActivity.swift`](../ios/doit/doitActivityWidget/HermesLiveActivity.swift),
   `ThinkingShimmerView`, `ActivityStepRow`, `AgentActivityCard`) is
   adapted from
   [`newmaterialco/chowder-iOS`](https://github.com/newmaterialco/chowder-iOS).
   The data schema, tool taxonomy, and lifecycle are Doit-specific —
   do not pull Chowder's `ChowderActivityAttributes`, tool enums, or
   ActivityKit manager logic into this repo.
7. **Do not render raw chain-of-thought.** `reasoning.available` events
   may contain provider-specific reasoning text. The activity service
   collapses them to a generic "Thinking" phase. Do not surface the raw
   text in any UI.

### Where it's wired

| Concern                          | File                                                                                                |
| -------------------------------- | --------------------------------------------------------------------------------------------------- |
| Translate raw event → snapshot   | [`runner/runner/activity.py`](../runner/runner/activity.py)                                          |
| Persist snapshot                 | [`runner/runner/db.py`](../runner/runner/db.py) `upsert_agent_activity` / `clear_agent_activity`     |
| Call from runner loop            | [`runner/runner/runner.py`](../runner/runner/runner.py) `_consume_run`, `prepare_one_todo`, `run_one_todo` |
| Realtime subscription            | [`ios/doit/doit/Supabase/TodoRealtimeHub.swift`](../ios/doit/doit/Supabase/TodoRealtimeHub.swift) `todo_agent_activity` task |
| Store + Live Activity wiring     | [`ios/doit/doit/Stores/TodoStore.swift`](../ios/doit/doit/Stores/TodoStore.swift) `agentActivityByTodoID`, `syncLiveActivities()` |
| Live Activity manager            | [`ios/doit/doit/Stores/AgentLiveActivityManager.swift`](../ios/doit/doit/Stores/AgentLiveActivityManager.swift) |
| Shared widget schema             | [`ios/doit/Shared/HermesActivityAttributes.swift`](../ios/doit/Shared/HermesActivityAttributes.swift) |
| Widget target                    | [`ios/doit/doitActivityWidget/`](../ios/doit/doitActivityWidget/)                                    |
| Snapshot derivation tests        | [`runner/tests/test_activity.py`](../runner/tests/test_activity.py)                                  |
| Migration                        | [`supabase/migrations/20240601000015_todo_agent_activity.sql`](../supabase/migrations/20240601000015_todo_agent_activity.sql) |

## Push notifications

APNs is a **backup** channel for when the app is backgrounded or closed.
`runner/runner/push.py` sends pushes for terminal / pause events
(`done`, `failed`, `oauth_needed`, `needs_input`, `tasks_spawned`,
`cron_needs_input`, `cron_failed`). Each payload carries the `todo_id`
when there is one.

On the iOS side:

- Foreground push (`AppDelegate.willPresent`) posts `.todoRemoteUpdate` with
  the `todo_id`. The list listens and refreshes that single row through the
  store; the detail view refreshes its chat-only state.
- Tapping a notification (`AppDelegate.didReceive` →
  `PushManager.handleNotificationTap`) sets `PushManager.pendingTodoID`.
  The list observes that property, refreshes the row, and pushes
  `TodoListDestination.todo(id)` onto the navigation path.

Push is **not** the primary path. The app must stay in sync via realtime
when foregrounded; pushes only cover the case where realtime is offline
because the app isn't running.

## Rules for future changes (read this before editing)

1. **No view-local task caches.** Do not add `@State private var todos`,
   `@State private var interactions`, `@State private var artifacts`, etc.
   to any view. Read from `TodoStore` via `@Environment(TodoStore.self)`.

2. **No timed polling as a primary fix.** If a row isn't updating, the
   answer is to fix the realtime → store path, not to add a `Timer` or a
   `Task.sleep` loop in a view. Realtime is the contract; polling is a
   bandaid that drifts and burns battery.

3. **Mutations go through the store.** When the user taps Do it, completes
   a task, responds to an interaction, sends a chat message, or deletes a
   task, call `store.request(...)`, `store.toggleComplete(...)`,
   `store.respond(...)`, `store.setStatus(...)`, `store.deleteTodo(...)`,
   etc. The store handles the optimistic local mutation and the API call so
   the list and detail stay in sync.

4. **Navigate by id, not by snapshot.** `NavigationStack` pushes
   `TodoListDestination.todo(UUID)` / `.cronJob(UUID)`. The detail view
   reads `store.todo(id:)` / `store.cronJob(id:)`. This way realtime updates
   to the row reach the detail view header automatically — pushing a
   `Todo` value would freeze the header at the moment of the tap.

5. **Realtime payload decoding is opt-in.** The hub only pulls row ids out
   of the payload; the store does a typed REST fetch for the merged data.
   If you want to short-circuit and apply the payload directly, make sure
   the date decoder and column casts match `TodosAPI.list()` first. The
   simple "fetch by id" path is the safer default.

6. **Add new tables to the user feed deliberately.** New child tables of
   `todos` should either go on the user feed (if the list needs them) or
   the per-todo detail feed (if only the detail needs them). Pick one;
   don't subscribe to the same table from both feeds.

7. **Don't reach into `Supa.client` from views.** Views should call
   `TodosAPI` / `CronJobsAPI` / `TodoStore`. Direct PostgREST in a view
   bypasses the store and creates the kind of drift this whole system
   exists to prevent.

8. **Sign-out tears down the store.** `doitApp` calls `todoStore.stop()`
   when auth flips to `signedOut`. If you add user-scoped state somewhere
   else (besides `TodoStore` and `PushManager`), wire it up the same way
   so a second sign-in on the same device doesn't see leftover rows.

## Where to look if it breaks

Symptom: "the list spins on the preparing card forever and only updates when
I open the task."

1. Check Xcode logs for `[realtime][hub][todos] subscribe FAILED` or
   `stream ended` lines. If the channel keeps reconnecting the user feed
   isn't delivering events. Verify the user is signed in and
   `TodoStore.start(userID:)` was called.
2. Check for `[realtime][hub][todos] event #N` lines — those mean the hub
   saw the row change. If you see them but the list is still stale, look
   for view-local `@State` caches that should be deleting (rule 1).
3. Confirm the runner is actually writing the row: the prep pass logs
   `prep result todo=<id>` and then calls `db.update_todo`. If the runner
   path is broken, no amount of iOS work will help.
4. Confirm the table is on the realtime publication. The migrations listed
   above add `todos`, `todo_interactions`, `todo_artifacts`, `cron_jobs`,
   etc. Run `select * from pg_publication_tables where pubname =
   'supabase_realtime';` in the Supabase SQL editor if in doubt.
