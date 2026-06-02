# iOS coding rules (read me first)

This project has a single, app-scoped source of truth for everything that
renders on the task list / detail screens. Read
[`/docs/task-realtime.md`](../../docs/task-realtime.md) before touching
anything in `Views/TodoListView.swift`, `Views/TodoDetailView.swift`,
`Views/CronJobDetailView.swift`, `Supabase/TodoRealtimeHub.swift`, or
`Stores/TodoStore.swift`.

## Hard rules

1. **No view-local task caches.** Do not add `@State private var todos`,
   `@State private var interactions`, `@State private var artifacts`,
   `@State private var cronJobs`, or similar to any view. Read from
   `TodoStore` via `@Environment(TodoStore.self) private var store` and
   render from `store.todos`, `store.cronJobs`, `store.openInteractions`,
   `store.artifactsByTodoID`, `store.interactions(for:)`. The store is
   `@Observable`, so views re-render automatically on change.

2. **No timed polling as a primary fix for "the list is stale".** If a row
   isn't updating live, fix the realtime → store path. Don't add `Timer`,
   `Task.sleep` loops, or scene-phase refreshes as the main mechanism.
   Realtime + the store is the contract.

3. **Mutations go through `TodoStore`.** The user-facing actions (do it,
   cancel, complete, respond to an interaction, send a message, delete,
   pause/resume cron, delete cron) all have store methods. Use them — they
   handle optimistic local updates AND the API call together so the list
   and detail stay in sync.

4. **Navigate by id.** `NavigationStack` pushes `TodoListDestination.todo(UUID)`
   / `.cronJob(UUID)`. The detail views (`TodoDetailView`, `CronJobDetailView`)
   take the id and read the latest row from the store. Don't go back to
   passing a `Todo` / `CronJob` snapshot through the navigation path —
   that's how the header froze before.

5. **Don't reach into `Supa.client` from a view.** Views call the typed
   APIs (`TodosAPI`, `CronJobsAPI`, `AttachmentsAPI`, …) or the store. The
   store is the only place that orchestrates per-row REST fetches in
   response to realtime events.

6. **New tables that need to render live go in the user feed or the
   per-todo watch — not both.** Add the table to
   `TodoRealtimeHub.runUserFeed` if the list needs it (and extend
   `UserFeedHandlers` + `TodoStore`). Add it to `beginTodoWatch` /
   `beginCronJobWatch` if only the detail view needs it. Don't duplicate.

7. **Sign-out must drop user-scoped state.** `doitApp` calls
   `todoStore.stop()` on `signedOut`. If you add a new user-scoped store,
   wire its start/stop the same way.

8. **Live agent activity belongs in `TodoStore`, not in a view.** The
   "what is Hermes doing right now" snapshot for the active todos lives
   in `store.agentActivityByTodoID` and is driven by Supabase Realtime on
   `todo_agent_activity`. Three surfaces consume it: the todo card status
   line, the `AgentActivityCard` in `TaskHeaderView`, and the ActivityKit
   Live Activity (Lock Screen / Dynamic Island). Do not derive activity
   text from `todo_steps` on the client, and do not call
   `Activity.request` / `.update` / `.end` from a view — that's
   `AgentLiveActivityManager`'s job. Read
   [`/docs/task-realtime.md`](../../docs/task-realtime.md) §"Agent
   activity service" before changing anything in this chain.

## Quick reference

| You want to…                                | Call this                            |
| ------------------------------------------- | ------------------------------------ |
| Read the list                               | `store.todos`                        |
| Read a single task in detail                | `store.todo(id:)`                    |
| Read open interaction for a card            | `store.openInteractions[todoID]`     |
| Read full interaction history for the chat  | `store.interactions(for:)`           |
| Read artifacts                              | `store.artifactsByTodoID[todoID]`    |
| Insert a freshly created todo               | `store.insertOptimistic(_:)`         |
| Flip a status                               | `store.setStatus(_:_:)`              |
| Tap-to-complete                             | `store.toggleComplete(_:)`           |
| "Do it"                                     | `store.request(_:)`                  |
| Cancel                                      | `store.cancel(_:)`                   |
| Delete                                      | `store.deleteTodo(_:)`               |
| Respond to an interaction                   | `store.respond(to:todo:optionID:text:)` |
| Toggle cron pause                           | `store.toggleCronPause(_:)`          |
| Delete cron                                 | `store.deleteCronJob(_:)`            |
| Force a single-row refresh                  | `store.refreshTodo(id:)` / `refreshCronJob(id:)` |
| Read live agent activity (one todo)         | `store.agentActivity(for: todoID)`   |
| Read live agent activity (list)             | `store.agentActivityByTodoID[todoID]` |
| Force activity refresh (e.g. scene active)  | `store.refreshAgentActivity(for:)` / `refreshAllAgentActivities()` |
| Force a full reload                         | `store.loadAll()` (only on scene-active fallback) |

## Tests / verification

After any change to the list, detail, hub, or store, run an iOS build:

```bash
cd ios/doit
xcodebuild -project doit.xcodeproj -scheme doit \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

Then manually verify on a simulator or device:

1. Create a new todo.
2. Watch the placeholder "Preparing task…" card flip to a real title +
   connection logo without tapping into the task.
3. If prep clarifies, watch the inline reply pill appear on the list card.
4. Open the task; the header reflects the current row immediately.
5. Watch token count climb on the detail header while the runner streams.
6. Background the app, send a push from the runner; foregrounding should
   show the latest row.
7. While the runner is mid-tool-call, confirm:
   - the todo list card subtitle ticks through "Searching Gmail…",
     "Reviewing Gmail results", etc.
   - the detail header shows the animated `AgentActivityCard` with a
     shimmer line and a small stack of previous steps.
   - a Live Activity appears on the Lock Screen / Dynamic Island and
     ends with a final state (done / failed / waiting) instead of
     hanging on "Working…".
