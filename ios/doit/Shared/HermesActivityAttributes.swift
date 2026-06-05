import ActivityKit
import Foundation

/// Shared `ActivityAttributes` describing a single Hermes agent run.
///
/// Both the main app (`doit`) and the Live Activity widget extension
/// (`doitActivityWidget`) need this type, so it lives under
/// `ios/doit/Shared/` and is added to both targets via the project's
/// file-system synchronized groups.
///
/// The shape mirrors the visual language of `newmaterialco/chowder-iOS`
/// (`ChowderActivityAttributes`), renamed for Doit. Static `attributes`
/// hold metadata that doesn't change during the run; the dynamic
/// `ContentState` carries the live-status fields we update from the
/// Supabase Realtime → `TodoStore` → `AgentLiveActivityManager` chain.
///
/// Keep this file small and Foundation-only so the widget target can
/// build without importing the rest of the app.
public struct HermesActivityAttributes: ActivityAttributes {
    public typealias HermesStatus = ContentState

    /// Snapshot of the per-step intent shown in the widget's stack.
    /// Mirrors `AgentActivityStep` in the main app but lives in this
    /// shared module so the widget doesn't depend on `Models/AgentActivity.swift`.
    public struct WidgetIntent: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let symbolName: String
        public let isCompleted: Bool

        public init(
            id: String,
            title: String,
            symbolName: String,
            isCompleted: Bool
        ) {
            self.id = id
            self.title = title
            self.symbolName = symbolName
            self.isCompleted = isCompleted
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        /// Current intent rendered as the prominent shimmer line at the
        /// bottom of the Lock Screen layout / compact island. This is
        /// the human-facing detail copy from `AgentActivity.detail`
        /// (e.g. "Looking up flights from SFO to JFK on Tuesday").
        public let currentIntent: String
        /// Short subject/header shown in the Chowder-style header and final
        /// card. Usually the current Hermes activity title.
        public let subject: String?
        /// Compact tool-call label (e.g. "Browsing web", "Searching
        /// Gmail") shown alongside the human-facing `currentIntent`
        /// in supporting rows. Sourced from `AgentActivity.title`.
        /// Optional so older activities without it still decode.
        public let toolCallTitle: String?
        /// SF Symbol name for the current intent badge.
        public let currentSymbolName: String
        /// Previous intent (slides into the "behind" card on the Lock
        /// Screen layout, mirroring Chowder's stacked previous-intent
        /// effect). `nil` when the run just started.
        public let previousIntent: WidgetIntent?
        /// Two-cards-back intent for the deepest stack layer.
        public let secondPreviousIntent: WidgetIntent?
        /// Step counter shown next to the timer in the Dynamic Island
        /// expanded layout.
        public let stepNumber: Int
        /// One of "running", "paused", "completed", "failed". Drives
        /// whether the widget shows the shimmer animation or a settled
        /// card.
        public let state: String
        /// Run start time so the widget can render a live timer with
        /// `Text(timerInterval:)` and stay accurate even when the app
        /// is suspended.
        public let intentStartDate: Date
        /// Set on terminal updates so the widget can flip to its
        /// finished card.
        public let intentEndDate: Date?
        /// Optional cost/token badge. Reserved for future telemetry; nil
        /// keeps the Hermes status badge in the header.
        public let costTotal: String?

        public init(
            currentIntent: String,
            subject: String? = nil,
            toolCallTitle: String? = nil,
            currentSymbolName: String,
            previousIntent: WidgetIntent? = nil,
            secondPreviousIntent: WidgetIntent? = nil,
            stepNumber: Int = 0,
            state: String = "running",
            intentStartDate: Date = .now,
            intentEndDate: Date? = nil,
            costTotal: String? = nil
        ) {
            self.currentIntent = currentIntent
            self.subject = subject
            self.toolCallTitle = toolCallTitle
            self.currentSymbolName = currentSymbolName
            self.previousIntent = previousIntent
            self.secondPreviousIntent = secondPreviousIntent
            self.stepNumber = stepNumber
            self.state = state
            self.intentStartDate = intentStartDate
            self.intentEndDate = intentEndDate
            self.costTotal = costTotal
        }

        public var isRunning: Bool { state == "running" }
        public var isTerminal: Bool { state == "completed" || state == "failed" }
    }

    /// Stable id of the todo this activity tracks. We key live activities
    /// by todo id so a second run on the same todo updates in place.
    public let todoID: UUID
    /// Short, user-friendly task title (e.g. the rewritten title).
    public let taskTitle: String
    /// The prompt/title shown as the initial blue message bubble while
    /// Hermes has not completed a first tool/intent yet.
    public let userTask: String
    /// Optional connection slug (gmail, googlecalendar, …) the widget can
    /// use to pick an accent / logo.
    public let connectionSlug: String?
    /// Display name of the agent — currently always "Hermes" but kept
    /// dynamic so we can A/B copy without a code change.
    public let agentName: String

    public init(
        todoID: UUID,
        taskTitle: String,
        userTask: String? = nil,
        connectionSlug: String? = nil,
        agentName: String = "Hermes"
    ) {
        self.todoID = todoID
        self.taskTitle = taskTitle
        self.userTask = userTask ?? taskTitle
        self.connectionSlug = connectionSlug
        self.agentName = agentName
    }
}
