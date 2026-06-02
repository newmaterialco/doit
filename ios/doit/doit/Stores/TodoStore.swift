import Foundation
import Observation
import Supabase

/// App-scoped source of truth for everything that renders in the task list
/// and task detail views: todos, cron jobs, open interactions, artifacts,
/// and per-todo interaction history. Views observe this store and never
/// keep their own `@State` caches of these rows — that pattern kept getting
/// reintroduced and breaking realtime UI updates, because each view would
/// drift out of sync with Supabase the moment a refresh fired against a
/// different cache.
///
/// Data flow (see `docs/task-realtime.md`):
///
///   runner (service_role) → Postgres rows → Supabase Realtime
///                                                       │
///                                                       ▼
///                                       TodoRealtimeHub user feed
///                                                       │
///                                                       ▼
///                                            TodoStore (this file)
///                                                       │
///                                                       ▼
///                              TodoListView / TodoDetailView (observers)
///
/// The hub extracts row ids from `AnyAction.record` / `oldRecord` and calls
/// store methods like `refreshTodo(id:)`. The store then fetches the single
/// row via the typed REST API and merges it into its observable arrays. This
/// avoids decoding Realtime payloads with custom date strategies and keeps
/// the on-screen data consistent with what a fresh REST fetch would return.
///
/// All mutations from the UI (insert, request, cancel, complete, respond,
/// delete) flow through this store so optimistic local updates and the
/// eventual realtime reconciliation share a single code path.
@MainActor
@Observable
final class TodoStore {
    // MARK: - Observable state

    /// All todos for the signed-in user, most-recently-created first.
    var todos: [Todo] = []

    /// All cron jobs for the signed-in user, most-recently-created first.
    var cronJobs: [CronJob] = []

    /// Latest open interaction per todo (used by the list card).
    /// Derived from `interactionsByTodoID` where present, otherwise fetched
    /// individually via `TodosAPI.openInteraction(for:)`.
    var openInteractions: [UUID: TodoInteraction] = [:]

    /// Artifacts grouped by todo id (used by the list and detail header).
    var artifactsByTodoID: [UUID: [TodoArtifact]] = [:]

    /// Full interaction history per todo, populated on demand when a detail
    /// view begins tracking the todo. The list never needs this — it only
    /// uses `openInteractions`.
    var interactionsByTodoID: [UUID: [TodoInteraction]] = [:]

    /// Live agent activity snapshot per todo (one row per active todo
    /// written by the runner's `AgentActivityService`). Drives the
    /// changing status line on todo cards, the detail-view animated
    /// cards, and the Live Activity widget. Realtime updates from
    /// `todo_agent_activity` land here via the user feed.
    var agentActivityByTodoID: [UUID: AgentActivity] = [:] {
        didSet { syncLiveActivities() }
    }

    /// User-facing message when the initial `loadAll()` fails. Cleared on
    /// the next successful load. Per-row refresh failures only log.
    var loadError: String?

    /// True while a row-level interaction response is in-flight. The list
    /// uses this to render the inline reply pill in a loading state.
    var respondingInteractionID: UUID?

    /// Set immediately after `AddTodoView` creates a new todo, cleared when
    /// the row either lands in `todos` or vanishes (e.g. the prep pass
    /// converted it to a cron job). The list observes this to scroll the
    /// user back to the "Tasks" section and, if the row was converted to a
    /// cron, switch to the "Scheduled" section.
    var pendingNewTodoID: UUID?

    // MARK: - Internals

    private(set) var userID: UUID?

    /// Manager that owns the system Live Activities for in-flight todos.
    /// Reads from `agentActivityByTodoID` whenever it changes (or whenever
    /// the underlying `todos` titles change) and starts / updates / ends
    /// the matching ActivityKit activity. View code never touches this
    /// directly — the lifecycle has to outlive any single screen.
    private let liveActivityManager = AgentLiveActivityManager()
    /// Detail views call `beginTracking(todoID:)` while they're on screen so
    /// the store knows it should keep `interactionsByTodoID[todoID]` fresh
    /// rather than only the lightweight open-interaction summary.
    private var trackedTodoIDs: Set<UUID> = []

    // MARK: - Lifecycle

    /// Bootstrap the store for a freshly signed-in user. Idempotent: calling
    /// twice with the same id is a no-op (the realtime hub takes care of
    /// reusing existing channels). Call from `RootView` when auth flips to
    /// `signedIn`.
    func start(userID: UUID) {
        if self.userID == userID { return }
        stop()
        self.userID = userID

        TodoRealtimeHub.startUserFeed(
            userID: userID,
            handlers: makeUserFeedHandlers()
        )

        Task { await loadAll() }
    }

    /// Tear everything down on sign-out. Drops local caches so a different
    /// user signing in on the same device doesn't see stale data.
    func stop() {
        TodoRealtimeHub.stopUserFeed()
        liveActivityManager.endAll()
        userID = nil
        todos = []
        cronJobs = []
        openInteractions = [:]
        artifactsByTodoID = [:]
        interactionsByTodoID = [:]
        agentActivityByTodoID = [:]
        trackedTodoIDs = []
        pendingNewTodoID = nil
        loadError = nil
    }

    // MARK: - Reads

    func todo(id: UUID) -> Todo? {
        todos.first(where: { $0.id == id })
    }

    func cronJob(id: UUID) -> CronJob? {
        cronJobs.first(where: { $0.id == id })
    }

    func interactions(for todoID: UUID) -> [TodoInteraction] {
        interactionsByTodoID[todoID] ?? []
    }

    func artifacts(for todoID: UUID) -> [TodoArtifact] {
        artifactsByTodoID[todoID] ?? []
    }

    /// Live agent activity snapshot for the given todo, or nil when the
    /// runner hasn't written one yet (freshly-created todos, or runs
    /// that never started).
    func agentActivity(for todoID: UUID) -> AgentActivity? {
        agentActivityByTodoID[todoID]
    }

    // MARK: - Detail tracking

    /// A detail view starts observing a todo. We refresh the row + its
    /// artifacts + the full interaction history immediately so the header is
    /// up-to-date even if the user landed here via a stale list snapshot or
    /// a push.
    func beginTracking(todoID: UUID) {
        trackedTodoIDs.insert(todoID)
        Task {
            await refreshTodo(id: todoID)
            await refreshArtifacts(for: todoID)
            await refreshInteractions(for: todoID)
            await refreshAgentActivity(for: todoID)
        }
    }

    func endTracking(todoID: UUID) {
        trackedTodoIDs.remove(todoID)
        // We deliberately keep the cached interactions/artifacts around —
        // the user is likely to come back to the same todo, and the data
        // is small. They'll be evicted naturally on `stop()`.
    }

    // MARK: - Full refresh

    /// Full reload from REST. Used on `start()`, scene activation, and as a
    /// fallback when the realtime hub reports an unidentified change.
    func loadAll() async {
        do {
            async let todosTask = TodosAPI.list()
            async let cronTask: [CronJob] = (try? await CronJobsAPI.list()) ?? []
            let fetched = try await todosTask
            todos = fetched
            cronJobs = await cronTask
            loadError = nil
            await refreshAllOpenInteractions()
            await refreshAllArtifacts()
            await refreshAllAgentActivities()
            for id in trackedTodoIDs {
                await refreshInteractions(for: id)
            }
        } catch {
            print("[store] loadAll failed: \(error)")
            loadError = "Couldn't load todos: \(error.localizedDescription)"
        }
    }

    // MARK: - Single-row refresh

    /// Fetch one todo row and merge it. Used by realtime when a `todos`
    /// row changes and by detail views on appear. If the row is gone
    /// (RLS or delete) we remove it locally too.
    func refreshTodo(id: UUID) async {
        do {
            let rows: [Todo] = try await Supa.client
                .from("todos")
                .select()
                .eq("id", value: id)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                print("[store] refreshTodo id=\(id) status=\(row.status.rawValue) title=\(row.title)")
                upsertTodo(row)
            } else {
                print("[store] refreshTodo id=\(id) not found; removing")
                removeTodoLocal(id: id)
            }
        } catch {
            print("[store] refreshTodo(\(id)) failed: \(error)")
        }
    }

    func refreshOpenInteraction(for todoID: UUID) async {
        do {
            let interaction = try await TodosAPI.openInteraction(for: todoID)
            if let interaction {
                openInteractions[todoID] = interaction
            } else {
                openInteractions.removeValue(forKey: todoID)
            }
        } catch {
            print("[store] refreshOpenInteraction(\(todoID)) failed: \(error)")
        }
    }

    func refreshArtifacts(for todoID: UUID) async {
        do {
            let rows = try await TodosAPI.artifacts(for: todoID)
            let filtered = rows.filter(\.hasContent)
            if filtered.isEmpty {
                artifactsByTodoID.removeValue(forKey: todoID)
            } else {
                artifactsByTodoID[todoID] = filtered
            }
        } catch {
            print("[store] refreshArtifacts(\(todoID)) failed: \(error)")
        }
    }

    func refreshInteractions(for todoID: UUID) async {
        do {
            let rows = try await TodosAPI.interactions(for: todoID)
            // Preserve optimistic local mutations: if the server still has
            // an interaction `.open` but we already flipped it to
            // `.responded` locally, keep our copy until the runner echoes.
            let prior = interactionsByTodoID[todoID] ?? []
            let merged = rows.map { remote -> TodoInteraction in
                if let local = prior.first(where: { $0.id == remote.id }),
                   remote.status == .open,
                   local.status != .open {
                    return local
                }
                return remote
            }
            interactionsByTodoID[todoID] = merged
            if let open = merged.last(where: { $0.status == .open }) {
                openInteractions[todoID] = open
            } else {
                openInteractions.removeValue(forKey: todoID)
            }
        } catch {
            print("[store] refreshInteractions(\(todoID)) failed: \(error)")
        }
    }

    /// Refresh the live agent activity snapshot for one todo. The user
    /// feed calls this whenever a `todo_agent_activity` row changes; the
    /// detail view also calls it on `beginTracking` so the header card
    /// is fresh after a navigation push.
    func refreshAgentActivity(for todoID: UUID) async {
        do {
            let activity = try await TodosAPI.agentActivity(for: todoID)
            if let activity {
                print("[store] refreshAgentActivity todo=\(todoID) phase=\(activity.phase) state=\(activity.state) title=\(activity.title) updated=\(activity.updated_at)")
                agentActivityByTodoID[todoID] = activity
            } else {
                print("[store] refreshAgentActivity todo=\(todoID) not found; clearing")
                agentActivityByTodoID.removeValue(forKey: todoID)
            }
        } catch {
            print("[store] refreshAgentActivity(\(todoID)) failed: \(error)")
        }
    }

    func refreshCronJob(id: UUID) async {
        do {
            let job = try await CronJobsAPI.fetch(id)
            upsertCronJob(job)
        } catch CronJobsAPIError.notFound {
            removeCronJobLocal(id: id)
        } catch {
            print("[store] refreshCronJob(\(id)) failed: \(error)")
        }
    }

    // MARK: - Batch refresh

    private func refreshAllOpenInteractions() async {
        let ids = todos.filter { $0.status == .needs_input }.map(\.id)
        guard !ids.isEmpty else {
            openInteractions = [:]
            return
        }
        do {
            openInteractions = try await TodosAPI.openInteractions(for: ids)
        } catch {
            print("[store] refreshAllOpenInteractions failed: \(error)")
        }
    }

    private func refreshAllArtifacts() async {
        let ids = todos.map(\.id)
        guard !ids.isEmpty else {
            artifactsByTodoID = [:]
            return
        }
        do {
            let raw = try await TodosAPI.artifacts(for: ids)
            artifactsByTodoID = raw.mapValues { $0.filter(\.hasContent) }
        } catch {
            print("[store] refreshAllArtifacts failed: \(error)")
        }
    }

    private func refreshAllAgentActivities() async {
        let ids = todos.map(\.id)
        guard !ids.isEmpty else {
            agentActivityByTodoID = [:]
            return
        }
        do {
            agentActivityByTodoID = try await TodosAPI.agentActivities(for: ids)
        } catch {
            print("[store] refreshAllAgentActivities failed: \(error)")
        }
    }

    // MARK: - Mutations (called from views)

    /// Append a row that was just inserted by `AddTodoView` so the list
    /// shows the placeholder immediately. The runner's prep pass will then
    /// update the same row and the realtime path will reconcile.
    func insertOptimistic(_ todo: Todo) {
        pendingNewTodoID = todo.id
        upsertTodo(todo)
    }

    func setStatus(_ id: UUID, _ status: TodoStatus) async {
        patchTodoLocal(id: id) { $0.status = status }
        do {
            try await TodosAPI.setStatus(id, status)
        } catch {
            print("[store] setStatus(\(id), \(status)) failed: \(error)")
            await refreshTodo(id: id)
        }
    }

    func request(_ todo: Todo) async {
        await setStatus(todo.id, .requested)
    }

    func cancel(_ todo: Todo) async {
        await setStatus(todo.id, .cancelled)
    }

    /// Flip a todo between `done` and `todo` from the card's circle toggle.
    func toggleComplete(_ todo: Todo) async {
        let next: TodoStatus = todo.status == .done ? .todo : .done
        await setStatus(todo.id, next)
    }

    /// Hard-delete a todo (and its cascaded children). Removes locally
    /// first so the row disappears immediately even if the API call lags.
    func deleteTodo(_ id: UUID) async {
        removeTodoLocal(id: id)
        do {
            try await TodosAPI.delete(id)
        } catch {
            print("[store] deleteTodo(\(id)) failed: \(error)")
            // Refetch in case the delete failed on the server.
            await refreshTodo(id: id)
        }
    }

    /// Submit a structured interaction reply and re-queue the todo so the
    /// runner can resume.
    func respond(
        to interaction: TodoInteraction,
        todo: Todo,
        optionID: String?,
        text: String?
    ) async {
        respondingInteractionID = interaction.id
        defer { respondingInteractionID = nil }
        let phase: InteractionPhase = interaction.isPreparationPhase ? .prepare : .execute
        applyOptimisticInteractionResponse(
            interactionID: interaction.id,
            todoID: todo.id,
            optionID: optionID,
            text: text
        )
        let nextStatus: TodoStatus =
            optionID?.lowercased() == "cancel" ? .cancelled : phase.nextStatus
        patchTodoLocal(id: todo.id) { $0.status = nextStatus }
        do {
            try await TodosAPI.respond(
                to: interaction.id,
                todoID: todo.id,
                optionID: optionID,
                text: text,
                phase: phase
            )
        } catch {
            print("[store] respond failed: \(error)")
            await refreshTodo(id: todo.id)
            await refreshInteractions(for: todo.id)
            await refreshOpenInteraction(for: todo.id)
        }
    }

    /// Mutate the cached interaction row in place so the chat transcript
    /// reflects the new `.responded` state immediately, matching the format
    /// the server will eventually write (`{option_id, text}` under
    /// `response`). The realtime path reconciles when the runner echoes.
    func applyOptimisticInteractionResponse(
        interactionID: UUID,
        todoID: UUID,
        optionID: String?,
        text: String?
    ) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        var responseObj: [String: JSONValue] = [:]
        if let id = optionID, !id.isEmpty {
            responseObj["option_id"] = .string(id)
        }
        if let body = trimmed, !body.isEmpty {
            responseObj["text"] = .string(body)
        }
        let nextStatus: InteractionStatus =
            optionID?.lowercased() == "cancel" ? .cancelled : .responded
        let response: JSONValue? = responseObj.isEmpty ? nil : .object(responseObj)
        let now = Date()

        if var history = interactionsByTodoID[todoID],
           let idx = history.firstIndex(where: { $0.id == interactionID }) {
            history[idx].status = nextStatus
            history[idx].response = response
            history[idx].responded_at = now
            interactionsByTodoID[todoID] = history
        }
        if openInteractions[todoID]?.id == interactionID {
            openInteractions.removeValue(forKey: todoID)
        }
    }

    // MARK: - Cron mutations

    func toggleCronPause(_ job: CronJob) async {
        let pausing = job.state != .paused
        patchCronJobLocal(id: job.id) {
            $0.state = pausing ? .paused : .scheduled
            $0.enabled = !pausing
        }
        do {
            if pausing {
                try await CronJobsAPI.setState(job.id, .paused)
                try await CronJobsAPI.setEnabled(job.id, false)
            } else {
                try await CronJobsAPI.setEnabled(job.id, true)
                try await CronJobsAPI.setState(job.id, .scheduled)
            }
        } catch {
            print("[store] toggleCronPause(\(job.id)) failed: \(error)")
            await refreshCronJob(id: job.id)
        }
    }

    func deleteCronJob(_ id: UUID) async {
        removeCronJobLocal(id: id)
        do {
            try await CronJobsAPI.delete(id)
        } catch {
            print("[store] deleteCronJob(\(id)) failed: \(error)")
            await refreshCronJob(id: id)
        }
    }

    // MARK: - Local upsert helpers

    /// Insert or replace a todo row, keeping the list ordered by
    /// `created_at` descending (matches `TodosAPI.list()`).
    private func upsertTodo(_ todo: Todo) {
        if let idx = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[idx] = todo
        } else {
            todos.append(todo)
            todos.sort { $0.created_at > $1.created_at }
        }
        syncLiveActivities()
        if todo.id == pendingNewTodoID, !todo.status.isActive {
            // Prep finished (status flipped to `todo` or `needs_input`);
            // we no longer need to track "pending" specifically. The list
            // can clear its highlight via its own observer.
            pendingNewTodoID = nil
        }
    }

    private func patchTodoLocal(id: UUID, _ mutate: (inout Todo) -> Void) {
        guard let idx = todos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&todos[idx])
    }

    private func removeTodoLocal(id: UUID) {
        todos.removeAll { $0.id == id }
        openInteractions.removeValue(forKey: id)
        artifactsByTodoID.removeValue(forKey: id)
        interactionsByTodoID.removeValue(forKey: id)
        agentActivityByTodoID.removeValue(forKey: id)
        // Don't clear pendingNewTodoID here; the list observer treats
        // "pending row vanished" + "new cron arrived" as a signal to flip
        // sections.
    }

    private func upsertCronJob(_ job: CronJob) {
        if let idx = cronJobs.firstIndex(where: { $0.id == job.id }) {
            cronJobs[idx] = job
        } else {
            cronJobs.append(job)
            cronJobs.sort { $0.created_at > $1.created_at }
        }
    }

    private func patchCronJobLocal(id: UUID, _ mutate: (inout CronJob) -> Void) {
        guard let idx = cronJobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&cronJobs[idx])
    }

    private func removeCronJobLocal(id: UUID) {
        cronJobs.removeAll { $0.id == id }
    }

    // MARK: - Realtime callbacks (wired into TodoRealtimeHub)

    private func makeUserFeedHandlers() -> TodoRealtimeHub.UserFeedHandlers {
        TodoRealtimeHub.UserFeedHandlers(
            onTodoChange: { [weak self] id in
                await self?.refreshTodo(id: id)
            },
            onTodoDelete: { [weak self] id in
                await MainActor.run { self?.removeTodoLocal(id: id) }
            },
            onInteractionChange: { [weak self] todoID in
                guard let self else { return }
                await self.refreshOpenInteraction(for: todoID)
                if self.trackedTodoIDs.contains(todoID) {
                    await self.refreshInteractions(for: todoID)
                }
            },
            onArtifactChange: { [weak self] todoID in
                await self?.refreshArtifacts(for: todoID)
            },
            onCronJobChange: { [weak self] id in
                await self?.refreshCronJob(id: id)
            },
            onCronJobDelete: { [weak self] id in
                await MainActor.run { self?.removeCronJobLocal(id: id) }
            },
            onAgentActivityChange: { [weak self] todoID, realtimeActivity in
                guard let self else { return }
                if let realtimeActivity {
                    print("[store] realtime activity todo=\(todoID) phase=\(realtimeActivity.phase) state=\(realtimeActivity.state) title=\(realtimeActivity.title)")
                    self.agentActivityByTodoID[todoID] = self.mergeRealtimeActivity(
                        realtimeActivity,
                        existing: self.agentActivityByTodoID[todoID]
                    )
                } else {
                    print("[store] realtime activity todo=\(todoID) missing payload; fetching")
                }
                await self.refreshAgentActivity(for: todoID)
            },
            onAgentActivityDelete: { [weak self] todoID in
                await MainActor.run {
                    _ = self?.agentActivityByTodoID.removeValue(forKey: todoID)
                }
            },
            onUnknown: { [weak self] in
                await self?.loadAll()
            }
        )
    }

    // MARK: - Live activity bridge

    /// Hand the current snapshot dictionary to the
    /// `AgentLiveActivityManager` so the Lock Screen / Dynamic Island
    /// surfaces stay in sync with the in-app card. Runs whenever
    /// `agentActivityByTodoID` or any todo title changes.
    private func syncLiveActivities() {
        let titles = Dictionary(
            uniqueKeysWithValues: todos.map { ($0.id, $0.title) }
        )
        liveActivityManager.sync(activities: agentActivityByTodoID, titles: titles)
    }

    private func mergeRealtimeActivity(
        _ realtime: AgentActivity,
        existing: AgentActivity?
    ) -> AgentActivity {
        guard realtime.payload == nil, let existing else { return realtime }
        return AgentActivity(
            todo_id: realtime.todo_id,
            user_id: realtime.user_id,
            hermes_run_id: realtime.hermes_run_id,
            phase: realtime.phase,
            state: realtime.state,
            title: realtime.title,
            detail: realtime.detail,
            tool_name: realtime.tool_name,
            tool_call_id: realtime.tool_call_id,
            tool_category: realtime.tool_category,
            payload: existing.payload,
            started_at: realtime.started_at,
            updated_at: realtime.updated_at,
            completed_at: realtime.completed_at
        )
    }
}
