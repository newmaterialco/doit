import Foundation
import Realtime
import Supabase

/// App-scoped Supabase realtime subscriptions. View `onDisappear` fires when
/// pushing a `NavigationStack` destination (and during split/layout churn),
/// which was cancelling in-flight `subscribeWithError()` and leaving channels
/// in a broken cached state. This hub keeps feeds alive across those transitions.
@MainActor
enum TodoRealtimeHub {
    struct TodoWatchHandlers {
        var onTodo: () async -> Void = {}
        var onSteps: () async -> Void = {}
        var onInteractions: () async -> Void = {}
        var onArtifacts: () async -> Void = {}
        var onMessages: () async -> Void = {}
    }

    struct CronJobWatchHandlers {
        var onJob: () async -> Void = {}
        var onInteractions: () async -> Void = {}
        var onMessages: () async -> Void = {}
    }

    private static var userTask: Task<Void, Never>?
    private static var activeUserID: UUID?
    private static var userOnChange: (() async -> Void)?

    private static var todoWatchID: UUID?
    private static var todoHandlers = TodoWatchHandlers()
    private static var todoTasks: [String: Task<Void, Never>] = [:]

    private static var cronWatchID: UUID?
    private static var cronHandlers = CronJobWatchHandlers()
    private static var cronTasks: [String: Task<Void, Never>] = [:]

    // MARK: - User feed (todo list)

    /// Start (or refresh) the user-wide `todos` + `todo_interactions` feeds.
    /// Call from `TodoListView` via `.task(id: userID)` — not from
    /// `onAppear` / `onDisappear`.
    static func startUserFeed(userID: UUID, onChange: @escaping () async -> Void) {
        userOnChange = onChange
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
        userOnChange = nil
    }

    // MARK: - Todo detail feed

    /// Begin detail-level feeds for a single todo. Handlers may be updated
    /// while the same `todoID` is active. Does not stop on view `onDisappear`;
    /// call `endTodoWatch()` when the navigation stack pops back to the list.
    static func beginTodoWatch(todoID: UUID, handlers: TodoWatchHandlers) {
        todoHandlers = handlers
        if todoWatchID == todoID, !todoTasks.isEmpty {
            print("[realtime][hub] todo watch handlers updated todo=\(todoID)")
            return
        }
        endTodoWatch()
        todoWatchID = todoID
        print("[realtime][hub] starting todo watch todo=\(todoID)")
        startTodoChannel(
            key: "steps",
            channelName: "steps:\(todoID.uuidString)",
            table: "todo_steps",
            filter: "todo_id=eq.\(todoID.uuidString)",
            onEvent: { await todoHandlers.onSteps() }
        )
        startTodoChannel(
            key: "todo",
            channelName: "todo:\(todoID.uuidString)",
            table: "todos",
            filter: "id=eq.\(todoID.uuidString)",
            onEvent: { await todoHandlers.onTodo() }
        )
        startTodoChannel(
            key: "interactions",
            channelName: "interactions:\(todoID.uuidString)",
            table: "todo_interactions",
            filter: "todo_id=eq.\(todoID.uuidString)",
            onEvent: { await todoHandlers.onInteractions() }
        )
        startTodoChannel(
            key: "artifacts",
            channelName: "artifacts:\(todoID.uuidString)",
            table: "todo_artifacts",
            filter: "todo_id=eq.\(todoID.uuidString)",
            onEvent: { await todoHandlers.onArtifacts() }
        )
        startTodoChannel(
            key: "messages",
            channelName: "messages:\(todoID.uuidString)",
            table: "todo_messages",
            filter: "todo_id=eq.\(todoID.uuidString)",
            onEvent: { await todoHandlers.onMessages() }
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
        if cronWatchID == jobID, !cronTasks.isEmpty { return }
        endCronJobWatch()
        cronWatchID = jobID
        startChannel(
            key: "cron_job",
            channelName: "cron_job:\(jobID.uuidString)",
            table: "cron_jobs",
            filter: "id=eq.\(jobID.uuidString)",
            tasks: &cronTasks,
            onEvent: { await cronHandlers.onJob() }
        )
        startChannel(
            key: "cron_interactions",
            channelName: "cron_interactions:\(jobID.uuidString)",
            table: "cron_job_interactions",
            filter: "cron_job_id=eq.\(jobID.uuidString)",
            tasks: &cronTasks,
            onEvent: { await cronHandlers.onInteractions() }
        )
        startChannel(
            key: "cron_messages",
            channelName: "cron_messages:\(jobID.uuidString)",
            table: "cron_job_messages",
            filter: "cron_job_id=eq.\(jobID.uuidString)",
            tasks: &cronTasks,
            onEvent: { await cronHandlers.onMessages() }
        )
    }

    static func endCronJobWatch() {
        guard cronWatchID != nil || !cronTasks.isEmpty else { return }
        for (_, task) in cronTasks { task.cancel() }
        cronTasks.removeAll()
        cronWatchID = nil
        cronHandlers = CronJobWatchHandlers()
    }

    // MARK: - Loops

    private static func runUserFeed(userID: UUID) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await postgresWatchLoop(
                    label: "cron_jobs",
                    channelName: "public:cron_jobs:user=\(userID.uuidString)",
                    table: "cron_jobs",
                    filter: nil
                ) {
                    await userOnChange?()
                }
            }
            group.addTask {
                await postgresWatchLoop(
                    label: "todos",
                    channelName: "public:todos:user=\(userID.uuidString)",
                    table: "todos",
                    filter: nil
                ) {
                    await userOnChange?()
                }
            }
            group.addTask {
                await postgresWatchLoop(
                    label: "todo_interactions",
                    channelName: "public:todo_interactions:user=\(userID.uuidString)",
                    table: "todo_interactions",
                    filter: nil
                ) {
                    await userOnChange?()
                }
            }
            group.addTask {
                await postgresWatchLoop(
                    label: "todo_artifacts",
                    channelName: "public:todo_artifacts:user=\(userID.uuidString)",
                    table: "todo_artifacts",
                    filter: "user_id=eq.\(userID.uuidString)"
                ) {
                    await userOnChange?()
                }
            }
        }
    }

    private static func startTodoChannel(
        key: String,
        channelName: String,
        table: String,
        filter: String,
        onEvent: @escaping () async -> Void
    ) {
        startChannel(
            key: key,
            channelName: channelName,
            table: table,
            filter: filter,
            tasks: &todoTasks,
            onEvent: onEvent
        )
    }

    private static func startChannel(
        key: String,
        channelName: String,
        table: String,
        filter: String,
        tasks: inout [String: Task<Void, Never>],
        onEvent: @escaping () async -> Void
    ) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            await postgresWatchLoop(
                label: key,
                channelName: channelName,
                table: table,
                filter: filter,
                onEvent: onEvent
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
        onEvent: @escaping () async -> Void
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
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            var eventCount = 0
            for await change in stream {
                if Task.isCancelled { break }
                eventCount += 1
                print("[realtime][hub][\(label)] event #\(eventCount): \(change)")
                await onEvent()
            }
            await Supa.client.removeChannel(channel)
            print("[realtime][hub][\(label)] stream ended events=\(eventCount) cancelled=\(Task.isCancelled)")
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
