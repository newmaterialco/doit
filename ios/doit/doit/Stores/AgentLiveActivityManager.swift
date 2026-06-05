import ActivityKit
import Foundation
import Observation
import UIKit

/// Bridges Doit's per-todo `AgentActivity` snapshots to the system
/// ActivityKit Live Activity API. One activity per running todo on
/// the device.
///
/// Lifecycle:
///   * `sync(activities:)` is called from `TodoStore` whenever its
///     `agentActivityByTodoID` changes. We start, update, or end the
///     matching system activity based on the snapshot's `state`.
///   * Updates are debounced so we don't spam the system with a token
///     update on every micro-event — Apple recommends throttling to
///     keep budget.
///   * On sign-out the manager ends every owned activity so a second
///     user signing in on the device doesn't inherit Lock Screen
///     placeholders from the previous one.
///
/// Visual styling is implemented in the widget extension target
/// (`HermesLiveActivity.swift`), inspired by the layout in the open-
/// source `newmaterialco/chowder-iOS` repo. This file only owns
/// lifecycle — never views.
@MainActor
@Observable
final class AgentLiveActivityManager {
    /// Currently-managed activities keyed by todo id. We keep our own
    /// map rather than relying on `Activity<HermesActivityAttributes>.activities`
    /// so we can apply local rate limiting and dedupe by todo id.
    private var owned: [UUID: Activity<HermesActivityAttributes>] = [:]
    private var lastUpdate: [UUID: Date] = [:]
    private var lastStateSignature: [UUID: String] = [:]
    private var pendingUpdateTasks: [UUID: Task<Void, Never>] = [:]
    private var terminalDismissTasks: [UUID: Task<Void, Never>] = [:]

    /// How long a completed / failed Live Activity should remain visible
    /// after Hermes returns. Keep this short: the detail view and chat are
    /// the durable result surfaces, while the Live Activity is progress UI.
    private let terminalDismissalDelay: TimeInterval = 12

    /// Minimum time between updates per todo. Tweak with system feedback —
    /// the docs recommend keeping updates relatively rare to stay within
    /// the activity budget.
    private let updateThrottle: TimeInterval = 1.5

    init() {
        // Restore in-memory references for any activities that survived an
        // app relaunch so we can update / end them later.
        for activity in Activity<HermesActivityAttributes>.activities {
            owned[activity.attributes.todoID] = activity
        }
    }

    /// Reconcile owned activities against a fresh snapshot of all live
    /// `AgentActivity` rows from `TodoStore`. Caller looks up titles via
    /// the matching `Todo` row so the activity attributes have a clean
    /// display name even if the snapshot title shifts mid-run.
    func sync(activities: [UUID: AgentActivity], titles: [UUID: String]) {
        let canStartOrUpdate = ActivityAuthorizationInfo().areActivitiesEnabled

        // Start / update activities for running snapshots. Ending happens
        // regardless of authorization so already-visible activities don't
        // get stranded if the user changes Live Activity permissions.
        for (todoID, snapshot) in activities {
            let taskTitle = titles[todoID] ?? snapshot.title
            if snapshot.isRunning || snapshot.resolvedState == .paused {
                guard canStartOrUpdate else { continue }
                terminalDismissTasks[todoID]?.cancel()
                terminalDismissTasks.removeValue(forKey: todoID)
                if let existing = owned[todoID] {
                    enqueueUpdate(existing, snapshot: snapshot, taskTitle: taskTitle)
                } else {
                    startActivity(for: todoID, snapshot: snapshot, taskTitle: taskTitle)
                }
            } else if snapshot.isTerminal {
                // Send one final update and end the activity. We keep the
                // finished card on screen for a few seconds so the user
                // sees the result before it dismisses.
                if let existing = owned[todoID], terminalDismissTasks[todoID] == nil {
                    pendingUpdateTasks[todoID]?.cancel()
                    pendingUpdateTasks.removeValue(forKey: todoID)
                    terminalDismissTasks[todoID] = Task { [weak self, existing] in
                        await self?.finishThenDismiss(
                            existing,
                            snapshot: snapshot,
                            taskTitle: taskTitle
                        )
                    }
                }
            }
        }

        // End any owned activities whose snapshot disappeared (todo was
        // deleted or the runner cleared the row).
        for (todoID, activity) in owned where activities[todoID] == nil {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            owned.removeValue(forKey: todoID)
            lastUpdate.removeValue(forKey: todoID)
            lastStateSignature.removeValue(forKey: todoID)
            pendingUpdateTasks[todoID]?.cancel()
            pendingUpdateTasks.removeValue(forKey: todoID)
            terminalDismissTasks[todoID]?.cancel()
            terminalDismissTasks.removeValue(forKey: todoID)
        }
    }

    /// End every owned activity. Called from `TodoStore.stop()` on sign-out.
    func endAll() {
        for (todoID, activity) in owned {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            owned.removeValue(forKey: todoID)
            lastUpdate.removeValue(forKey: todoID)
            lastStateSignature.removeValue(forKey: todoID)
            pendingUpdateTasks[todoID]?.cancel()
            pendingUpdateTasks.removeValue(forKey: todoID)
            terminalDismissTasks[todoID]?.cancel()
            terminalDismissTasks.removeValue(forKey: todoID)
        }
        lastUpdate.removeAll()
        lastStateSignature.removeAll()
        pendingUpdateTasks.removeAll()
        terminalDismissTasks.removeAll()
    }

    // MARK: - Internals

    private func startActivity(
        for todoID: UUID,
        snapshot: AgentActivity,
        taskTitle: String
    ) {
        let attributes = HermesActivityAttributes(
            todoID: todoID,
            taskTitle: taskTitle,
            userTask: taskTitle,
            connectionSlug: nil,
            agentName: "doit"
        )
        let state = contentState(from: snapshot)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            owned[todoID] = activity
            lastUpdate[todoID] = Date()
            lastStateSignature[todoID] = signature(for: state)
            pendingUpdateTasks[todoID]?.cancel()
            pendingUpdateTasks.removeValue(forKey: todoID)
            terminalDismissTasks[todoID]?.cancel()
            terminalDismissTasks.removeValue(forKey: todoID)
        } catch {
            print("[live-activity] start failed todo=\(todoID) error=\(error)")
        }
    }

    private func enqueueUpdate(
        _ activity: Activity<HermesActivityAttributes>,
        snapshot: AgentActivity,
        taskTitle: String
    ) {
        let state = contentState(from: snapshot)
        let signature = signature(for: state)
        let todoID = activity.attributes.todoID
        guard lastStateSignature[todoID] != signature else { return }

        let now = Date()
        let last = lastUpdate[todoID] ?? .distantPast
        let resumedFromPause =
            lastStateSignature[todoID]?.hasPrefix("paused|") == true
            && state.state == "running"
        let shouldThrottle = !resumedFromPause && now.timeIntervalSince(last) < updateThrottle
        if shouldThrottle {
            let delay = max(0.05, updateThrottle - now.timeIntervalSince(last))
            pendingUpdateTasks[todoID]?.cancel()
            pendingUpdateTasks[todoID] = Task { [weak self, activity] in
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.applyUpdate(
                    activity,
                    state: state,
                    signature: signature
                )
            }
            return
        }

        pendingUpdateTasks[todoID]?.cancel()
        pendingUpdateTasks.removeValue(forKey: todoID)
        Task { await applyUpdate(activity, state: state, signature: signature) }
    }

    private func applyUpdate(
        _ activity: Activity<HermesActivityAttributes>,
        state: HermesActivityAttributes.ContentState,
        signature: String
    ) async {
        let todoID = activity.attributes.todoID
        guard owned[todoID]?.id == activity.id else { return }
        guard lastStateSignature[todoID] != signature else { return }
        lastUpdate[todoID] = Date()
        lastStateSignature[todoID] = signature
        pendingUpdateTasks.removeValue(forKey: todoID)
        print("[live-activity] update todo=\(todoID) state=\(state.state) intent=\(state.currentIntent) step=\(state.stepNumber)")
        await activity.update(.init(state: state, staleDate: nil))
    }

    private func finishThenDismiss(
        _ activity: Activity<HermesActivityAttributes>,
        snapshot: AgentActivity,
        taskTitle: String
    ) async {
        _ = taskTitle
        let todoID = activity.attributes.todoID
        let state = contentState(from: snapshot)
        let signature = signature(for: state)
        guard owned[todoID]?.id == activity.id else { return }
        lastUpdate[todoID] = Date()
        lastStateSignature[todoID] = signature
        print("[live-activity] finish todo=\(todoID) state=\(state.state) intent=\(state.currentIntent)")
        await activity.update(.init(state: state, staleDate: nil))

        try? await Task.sleep(nanoseconds: UInt64(terminalDismissalDelay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        guard owned[todoID]?.id == activity.id else { return }
        print("[live-activity] dismiss todo=\(todoID)")
        await activity.end(nil, dismissalPolicy: .immediate)
        cleanupActivity(todoID)
    }

    private func contentState(from snapshot: AgentActivity) -> HermesActivityAttributes.ContentState {
        let steps = snapshot.recentSteps
        let previous = steps.dropLast().last.map(intent(from:))
        let secondPrevious = steps.dropLast(2).last.map(intent(from:))
        let state: String
        switch snapshot.resolvedState {
        case .running: state = "running"
        case .paused: state = "paused"
        case .completed: state = "completed"
        case .failed: state = "failed"
        }
        let intentEndDate: Date?
        switch snapshot.resolvedState {
        case .completed, .failed:
            intentEndDate = snapshot.completed_at ?? snapshot.updated_at
        case .running, .paused:
            intentEndDate = nil
        }

        return HermesActivityAttributes.ContentState(
            currentIntent: snapshot.humanActivityText,
            subject: snapshot.humanActivityText,
            toolCallTitle: snapshot.toolCallText,
            currentSymbolName: snapshot.resolvedCategory.symbolName,
            previousIntent: previous,
            secondPreviousIntent: secondPrevious,
            stepNumber: steps.count,
            state: state,
            intentStartDate: snapshot.started_at,
            intentEndDate: intentEndDate
        )
    }

    private func intent(from step: AgentActivityStep) -> HermesActivityAttributes.WidgetIntent {
        HermesActivityAttributes.WidgetIntent(
            id: step.id,
            title: step.humanActivityText,
            symbolName: step.tool_category.symbolName,
            isCompleted: step.isCompleted
        )
    }

    private func signature(for state: HermesActivityAttributes.ContentState) -> String {
        [
            state.state,
            state.currentIntent,
            state.toolCallTitle ?? "-",
            state.currentSymbolName,
            "\(state.stepNumber)",
            state.previousIntent?.title ?? "-",
            state.previousIntent?.id ?? "-",
            state.secondPreviousIntent?.title ?? "-",
            state.secondPreviousIntent?.id ?? "-",
            state.intentEndDate == nil ? "open" : "ended"
        ].joined(separator: "|")
    }

    private func cleanupActivity(_ todoID: UUID) {
        owned.removeValue(forKey: todoID)
        lastUpdate.removeValue(forKey: todoID)
        lastStateSignature.removeValue(forKey: todoID)
        pendingUpdateTasks[todoID]?.cancel()
        pendingUpdateTasks.removeValue(forKey: todoID)
        terminalDismissTasks[todoID]?.cancel()
        terminalDismissTasks.removeValue(forKey: todoID)
    }
}
