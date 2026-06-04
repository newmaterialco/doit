import Foundation
import Realtime
import Supabase

/// App-scoped Supabase realtime subscriptions. View `onDisappear` fires when
/// pushing a `NavigationStack` destination (and during split/layout churn),
/// which was cancelling in-flight `subscribeWithError()` and leaving channels
/// in a broken cached state. This hub keeps feeds alive across those transitions.
///
/// Two long-lived feeds live here:
///
///  - **User feed**: subscribes to `todos`, `todo_interactions`,
///    `todo_artifacts`, and `cron_jobs` filtered by `user_id=eq.<userID>`.
///    Row-level change payloads are decoded into ids and handed to
///    `TodoStore` via `UserFeedHandlers`. The store does the typed REST
///    fetch and updates its observable arrays; views never own task data.
///  - **Detail feeds**: per-todo subscriptions for `todo_steps` and
///    `todo_messages` (chat-only state that the user feed does not carry).
///    Task row / interactions / artifacts updates already flow through the
///    user feed → store, so the detail view does not need to re-subscribe
///    to those tables; it just reads from the store.
///
/// IMPORTANT: do not start either feed from view `onAppear` / `onDisappear`.
/// Use `.task(id:)` from a stable scope (root view for the user feed,
/// detail view for the per-todo feed). The list view's `onAppear` fires
/// every time the user pushes a detail destination and was previously
/// cancelling in-flight channel joins.
@MainActor
enum TodoRealtimeHub {
    // MARK: - Handlers

    /// Row-level callbacks the user feed delivers to `TodoStore`. Each
    /// closure receives the affected row id (or parent todo id for child
    /// tables) so the store can fetch the single row instead of decoding
    /// the realtime payload itself.
    struct UserFeedHandlers {
        var onTodoChange: (UUID, Todo?) async -> Void = { _, _ in }
        var onTodoDelete: (UUID) async -> Void = { _ in }
        /// Fires for `todo_interactions` insert/update; `todoID` is the
        /// parent todo, not the interaction id.
        var onInteractionChange: (UUID) async -> Void = { _ in }
        /// Fires for `todo_artifacts` insert/update/delete; `todoID` is
        /// the parent todo.
        var onArtifactChange: (UUID) async -> Void = { _ in }
        var onCronJobChange: (UUID) async -> Void = { _ in }
        var onCronJobDelete: (UUID) async -> Void = { _ in }
        /// Fires for `todo_agent_activity` insert/update; `todoID` is the
        /// parent todo (PK of the activity row). The store then fetches
        /// the single typed row via REST so date decoding stays in one
        /// place.
        var onAgentActivityChange: (UUID, AgentActivity?) async -> Void = { _, _ in }
        var onAgentActivityDelete: (UUID) async -> Void = { _ in }
        /// Fallback when we can't pull a row id out of the payload —
        /// the store should run a full `loadAll()`.
        var onUnknown: () async -> Void = {}
    }

    /// Per-todo handlers for the detail view's chat-only tables.
    struct TodoWatchHandlers {
        var onSteps: () async -> Void = {}
        var onMessages: () async -> Void = {}
    }

    /// Per-cron-job handlers for the cron detail view's chat-only tables.
    /// Job row / interactions changes flow through the user feed → store
    /// like todos, so we only watch chat messages here.
    struct CronJobWatchHandlers {
        var onMessages: () async -> Void = {}
        var onInteractions: () async -> Void = {}
    }

    // MARK: - State

    private static var userTask: Task<Void, Never>?
    private static var activeUserID: UUID?
    private static var userHandlers = UserFeedHandlers()

    private static var todoWatchID: UUID?
    private static var todoHandlers = TodoWatchHandlers()
    private static var todoTasks: [String: Task<Void, Never>] = [:]

    private static var cronWatchID: UUID?
    private static var cronHandlers = CronJobWatchHandlers()
    private static var cronTasks: [String: Task<Void, Never>] = [:]

    // MARK: - User feed (todo list)

    /// Start (or refresh) the user-wide realtime feeds and route row-level
    /// payloads through `handlers`. Idempotent for a stable `userID`.
    /// Call from `TodoStore.start(userID:)` — not from a view lifecycle hook.
    static func startUserFeed(userID: UUID, handlers: UserFeedHandlers) {
        userHandlers = handlers
        if activeUserID == userID, userTask != nil {
            print("[realtime][hub] user feed already running user=\(userID)")
            return
        }
        userTask?.cancel()
        activeUserID = userID
        print("[realtime][hub] starting user feed user=\(userID)")
        userTask = Task {
            await runUserFeed(userID: userID)
            print("[realtime][hub] user feed task exit user=\(userID)")
        }
    }

    static func stopUserFeed() {
        print("[realtime][hub] stopping user feed user=\(activeUserID?.uuidString ?? "nil")")
        userTask?.cancel()
        userTask = nil
        activeUserID = nil
        userHandlers = UserFeedHandlers()
    }

    // MARK: - Todo detail feed

    /// Begin detail-level feeds for a single todo. Handlers may be updated
    /// while the same `todoID` is active. Does not stop on view
    /// `onDisappear`; call `endTodoWatch()` when navigation pops back.
    static func beginTodoWatch(todoID: UUID, handlers: TodoWatchHandlers) {
        todoHandlers = handlers
        if todoWatchID == todoID, !todoTasks.isEmpty {
            print("[realtime][hub] todo watch handlers updated todo=\(todoID)")
            return
        }
        endTodoWatch()
        todoWatchID = todoID
        print("[realtime][hub] starting todo watch todo=\(todoID)")
        startChannel(
            key: "steps",
            channelName: "steps:\(todoID.uuidString)",
            table: "todo_steps",
            filter: "todo_id=eq.\(todoID.uuidString)",
            tasks: &todoTasks,
            onAction: { _ in await todoHandlers.onSteps() }
        )
        startChannel(
            key: "messages",
            channelName: "messages:\(todoID.uuidString)",
            table: "todo_messages",
            filter: "todo_id=eq.\(todoID.uuidString)",
            tasks: &todoTasks,
            onAction: { _ in await todoHandlers.onMessages() }
        )
    }

    static func endTodoWatch() {
        guard todoWatchID != nil || !todoTasks.isEmpty else { return }
        print("[realtime][hub] ending todo watch todo=\(todoWatchID?.uuidString ?? "nil")")
        for (_, task) in todoTasks { task.cancel() }
        todoTasks.removeAll()
        todoWatchID = nil
        todoHandlers = TodoWatchHandlers()
    }

    // MARK: - Cron job detail feed

    static func beginCronJobWatch(jobID: UUID, handlers: CronJobWatchHandlers) {
        cronHandlers = handlers
        if cronWatchID == jobID, !cronTasks.isEmpty {
            print("[realtime][hub] cron watch handlers updated job=\(jobID)")
            return
        }
        endCronJobWatch()
        cronWatchID = jobID
        print("[realtime][hub] starting cron watch job=\(jobID)")
        startChannel(
            key: "cron_messages",
            channelName: "cron_messages:\(jobID.uuidString)",
            table: "cron_job_messages",
            filter: "cron_job_id=eq.\(jobID.uuidString)",
            tasks: &cronTasks,
            onAction: { _ in await cronHandlers.onMessages() }
        )
        startChannel(
            key: "cron_interactions",
            channelName: "cron_interactions:\(jobID.uuidString)",
            table: "cron_job_interactions",
            filter: "cron_job_id=eq.\(jobID.uuidString)",
            tasks: &cronTasks,
            onAction: { _ in await cronHandlers.onInteractions() }
        )
    }

    static func endCronJobWatch() {
        guard cronWatchID != nil || !cronTasks.isEmpty else { return }
        print("[realtime][hub] ending cron watch job=\(cronWatchID?.uuidString ?? "nil")")
        for (_, task) in cronTasks { task.cancel() }
        cronTasks.removeAll()
        cronWatchID = nil
        cronHandlers = CronJobWatchHandlers()
    }

    // MARK: - Loops

    private static func runUserFeed(userID: UUID) async {
        await userFeedWatchLoop(userID: userID)
    }

    // MARK: - Action routing

    private static func handleTodoAction(_ action: AnyAction) async {
        switch action {
        case .insert(let a):
            if let id = uuid(from: a.record, key: "id") {
                await userHandlers.onTodoChange(id, todo(from: a.record))
            } else {
                await userHandlers.onUnknown()
            }
        case .update(let a):
            if let id = uuid(from: a.record, key: "id") {
                await userHandlers.onTodoChange(id, todo(from: a.record))
            } else {
                await userHandlers.onUnknown()
            }
        case .delete(let a):
            if let id = uuid(from: a.oldRecord, key: "id") {
                await userHandlers.onTodoDelete(id)
            } else {
                await userHandlers.onUnknown()
            }
        }
    }

    private static func handleInteractionAction(_ action: AnyAction) async {
        switch action {
        case .insert(let a):
            if let todoID = uuid(from: a.record, key: "todo_id") {
                await userHandlers.onInteractionChange(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        case .update(let a):
            if let todoID = uuid(from: a.record, key: "todo_id") {
                await userHandlers.onInteractionChange(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        case .delete(let a):
            if let todoID = uuid(from: a.oldRecord, key: "todo_id") {
                await userHandlers.onInteractionChange(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        }
    }

    private static func handleArtifactAction(_ action: AnyAction) async {
        switch action {
        case .insert(let a):
            if let todoID = uuid(from: a.record, key: "todo_id") {
                await userHandlers.onArtifactChange(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        case .update(let a):
            if let todoID = uuid(from: a.record, key: "todo_id") {
                await userHandlers.onArtifactChange(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        case .delete(let a):
            if let todoID = uuid(from: a.oldRecord, key: "todo_id") {
                await userHandlers.onArtifactChange(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        }
    }

    private static func handleCronJobAction(_ action: AnyAction) async {
        switch action {
        case .insert(let a):
            if let id = uuid(from: a.record, key: "id") {
                await userHandlers.onCronJobChange(id)
            } else {
                await userHandlers.onUnknown()
            }
        case .update(let a):
            if let id = uuid(from: a.record, key: "id") {
                await userHandlers.onCronJobChange(id)
            } else {
                await userHandlers.onUnknown()
            }
        case .delete(let a):
            if let id = uuid(from: a.oldRecord, key: "id") {
                await userHandlers.onCronJobDelete(id)
            } else {
                await userHandlers.onUnknown()
            }
        }
    }

    private static func handleAgentActivityAction(_ action: AnyAction) async {
        switch action {
        case .insert(let a):
            if let todoID = uuid(from: a.record, key: "todo_id") {
                await userHandlers.onAgentActivityChange(
                    todoID,
                    agentActivity(from: a.record)
                )
            } else {
                await userHandlers.onUnknown()
            }
        case .update(let a):
            if let todoID = uuid(from: a.record, key: "todo_id") {
                await userHandlers.onAgentActivityChange(
                    todoID,
                    agentActivity(from: a.record)
                )
            } else {
                await userHandlers.onUnknown()
            }
        case .delete(let a):
            if let todoID = uuid(from: a.oldRecord, key: "todo_id") {
                await userHandlers.onAgentActivityDelete(todoID)
            } else {
                await userHandlers.onUnknown()
            }
        }
    }

    private static func uuid(from record: [String: AnyJSON], key: String) -> UUID? {
        guard let raw = record[key]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private static func agentActivity(from record: [String: AnyJSON]) -> AgentActivity? {
        guard let todoID = uuid(from: record, key: "todo_id"),
              let userID = uuid(from: record, key: "user_id"),
              let phase = record["phase"]?.stringValue,
              let state = record["state"]?.stringValue,
              let title = record["title"]?.stringValue,
              let startedAt = date(from: record["started_at"]?.stringValue),
              let updatedAt = date(from: record["updated_at"]?.stringValue) else {
            return nil
        }

        return AgentActivity(
            todo_id: todoID,
            user_id: userID,
            hermes_run_id: record["hermes_run_id"]?.stringValue,
            phase: phase,
            state: state,
            title: title,
            detail: record["detail"]?.stringValue,
            tool_name: record["tool_name"]?.stringValue,
            tool_call_id: record["tool_call_id"]?.stringValue,
            tool_category: record["tool_category"]?.stringValue,
            // The raw Realtime payload is enough to update the visible
            // status line immediately. A REST refinement below fills the
            // nested `payload.steps` history for the stacked activity cards.
            payload: nil,
            started_at: startedAt,
            updated_at: updatedAt,
            completed_at: date(from: record["completed_at"]?.stringValue)
        )
    }

    private static func todo(from record: [String: AnyJSON]) -> Todo? {
        guard let id = uuid(from: record, key: "id"),
              let userID = uuid(from: record, key: "user_id"),
              let title = record["title"]?.stringValue,
              let rawStatus = record["status"]?.stringValue,
              let status = TodoStatus(rawValue: rawStatus),
              let createdAt = date(from: record["created_at"]?.stringValue),
              let updatedAt = date(from: record["updated_at"]?.stringValue) else {
            return nil
        }

        return Todo(
            id: id,
            user_id: userID,
            title: title,
            detail: record["detail"]?.stringValue,
            status: status,
            hermes_run_id: record["hermes_run_id"]?.stringValue,
            hermes_session_id: record["hermes_session_id"]?.stringValue,
            error_message: record["error_message"]?.stringValue,
            original_title: record["original_title"]?.stringValue,
            connection_slug: record["connection_slug"]?.stringValue,
            preparation_summary: record["preparation_summary"]?.stringValue,
            total_tokens: record["total_tokens"]?.stringValue.flatMap(Int64.init),
            created_at: createdAt,
            updated_at: updatedAt,
            completed_at: date(from: record["completed_at"]?.stringValue)
        )
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    // MARK: - Channel plumbing

    /// One channel for the app-wide user feed.
    ///
    /// Keeping the list-critical tables on a single Realtime channel avoids
    /// racing five concurrent `subscribeWithError()` calls on the same
    /// socket. When those joins fail together, the app silently falls back
    /// to push/manual-navigation refreshes and the UI looks stale until the
    /// user opens/closes screens.
    private static func userFeedWatchLoop(userID: UUID) async {
        var attempt = 0
        let userFilter = "user_id=eq.\(userID.uuidString)"
        let channelName = "public:user_feed:user=\(userID.uuidString)"

        while !Task.isCancelled {
            attempt += 1
            let channel = Supa.client.channel(channelName)
            let todos = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todos",
                filter: userFilter
            )
            let interactions = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todo_interactions",
                filter: userFilter
            )
            let artifacts = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todo_artifacts",
                filter: userFilter
            )
            let cronJobs = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "cron_jobs",
                filter: userFilter
            )
            let agentActivity = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todo_agent_activity",
                filter: userFilter
            )

            do {
                try await channel.subscribeWithError()
                print("[realtime][hub][user_feed] subscribe ok status=\(channel.status) attempt=\(attempt)")
            } catch {
                print("[realtime][hub][user_feed] subscribe FAILED status=\(channel.status) error=\(error) attempt=\(attempt)")
                await Supa.client.removeChannel(channel)
                await userHandlers.onUnknown()
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(retryDelay(for: attempt)))
                continue
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await consumeStream(
                        label: "todos",
                        stream: todos,
                        onAction: handleTodoAction
                    )
                }
                group.addTask {
                    await consumeStream(
                        label: "todo_interactions",
                        stream: interactions,
                        onAction: handleInteractionAction
                    )
                }
                group.addTask {
                    await consumeStream(
                        label: "todo_artifacts",
                        stream: artifacts,
                        onAction: handleArtifactAction
                    )
                }
                group.addTask {
                    await consumeStream(
                        label: "cron_jobs",
                        stream: cronJobs,
                        onAction: handleCronJobAction
                    )
                }
                group.addTask {
                    await consumeStream(
                        label: "todo_agent_activity",
                        stream: agentActivity,
                        onAction: handleAgentActivityAction
                    )
                }
            }

            await Supa.client.removeChannel(channel)
            print("[realtime][hub][user_feed] stream ended cancelled=\(Task.isCancelled)")
            if Task.isCancelled { break }
            await userHandlers.onUnknown()
            try? await Task.sleep(for: .seconds(retryDelay(for: attempt)))
        }
    }

    private static func startChannel(
        key: String,
        channelName: String,
        table: String,
        filter: String?,
        tasks: inout [String: Task<Void, Never>],
        onAction: @escaping (AnyAction) async -> Void
    ) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            await postgresWatchLoop(
                label: key,
                channelName: channelName,
                table: table,
                filter: filter,
                onAction: onAction
            )
        }
    }

    /// Subscribe → consume → `removeChannel` → retry.
    /// `postgresChange` before `subscribeWithError`, and always removes the
    /// channel from the client cache before the next attempt.
    private static func postgresWatchLoop(
        label: String,
        channelName: String,
        table: String,
        filter: String?,
        onAction: @escaping (AnyAction) async -> Void
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            let channel = Supa.client.channel(channelName)
            let stream: AsyncStream<AnyAction>
            if let filter {
                stream = channel.postgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: table,
                    filter: filter
                )
            } else {
                stream = channel.postgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: table
                )
            }
            do {
                try await channel.subscribeWithError()
                print("[realtime][hub][\(label)] subscribe ok status=\(channel.status) attempt=\(attempt)")
            } catch {
                print("[realtime][hub][\(label)] subscribe FAILED status=\(channel.status) error=\(error) attempt=\(attempt)")
                await Supa.client.removeChannel(channel)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(retryDelay(for: attempt)))
                continue
            }
            await consumeStream(label: label, stream: stream, onAction: onAction)
            await Supa.client.removeChannel(channel)
            print("[realtime][hub][\(label)] stream ended cancelled=\(Task.isCancelled)")
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(retryDelay(for: attempt)))
        }
    }

    private static func consumeStream(
        label: String,
        stream: AsyncStream<AnyAction>,
        onAction: @escaping (AnyAction) async -> Void
    ) async {
        var eventCount = 0
        for await change in stream {
            if Task.isCancelled { break }
            eventCount += 1
            print("[realtime][hub][\(label)] event #\(eventCount)")
            await onAction(change)
        }
        print("[realtime][hub][\(label)] stream ended events=\(eventCount) cancelled=\(Task.isCancelled)")
    }

    private static func retryDelay(for attempt: Int) -> TimeInterval {
        min(8, max(1, TimeInterval(attempt)))
    }
}
