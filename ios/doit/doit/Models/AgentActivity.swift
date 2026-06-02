import Foundation

/// Live snapshot of what Hermes is doing for a single todo. Mirrors the
/// `todo_agent_activity` Postgres row written by the runner's
/// `AgentActivityService`. Drives three iOS surfaces from a single source:
///
///   * The status line on the todo card ("Searching Gmail…").
///   * The animated activity card pinned at the top of the task detail view.
///   * The Live Activity widget on the Lock Screen / Dynamic Island.
///
/// The runner does the SSE → label normalization once, so iOS doesn't need
/// to parse tool slugs or chain-of-thought. See
/// `runner/runner/activity.py` and `docs/task-realtime.md`.
struct AgentActivity: Codable, Identifiable, Hashable, Sendable {
    var id: UUID { todo_id }

    let todo_id: UUID
    let user_id: UUID
    let hermes_run_id: String?

    /// Coarse phase of the agent loop. Free-form text so the runner can
    /// iterate without forcing a migration; we recognize a handful of
    /// well-known values and fall back to a generic surface otherwise.
    /// See `AgentActivityPhase` for the values the iOS UI cares about.
    let phase: String

    /// Liveness — drives whether the UI shows the running shimmer or a
    /// settled "done" / "paused" card. One of: `running`, `paused`,
    /// `completed`, `failed`.
    let state: String

    /// Short human-readable label rendered as the current intent.
    let title: String
    let detail: String?

    let tool_name: String?
    let tool_call_id: String?
    let tool_category: String?

    let payload: JSONValue?

    let started_at: Date
    let updated_at: Date
    let completed_at: Date?

    // MARK: - Derived state

    /// Strongly-typed phase for the small set of cases the UI cares about.
    var resolvedPhase: AgentActivityPhase {
        AgentActivityPhase(rawValue: phase) ?? .unknown
    }

    /// Strongly-typed liveness state. Anything we don't recognize is
    /// treated as `.running` because the runner only writes settled
    /// states explicitly; a forward-compat unknown means "still going".
    var resolvedState: AgentActivityState {
        AgentActivityState(rawValue: state) ?? .running
    }

    /// Strongly-typed tool category. Drives the SF Symbol picker on the
    /// detail card and Live Activity. Falls back to `.unknown` when the
    /// runner couldn't classify the tool.
    var resolvedCategory: AgentToolCategory {
        guard let raw = tool_category else { return .unknown }
        return AgentToolCategory(rawValue: raw) ?? .unknown
    }

    /// True while the agent is actively making progress. The card shimmer
    /// only animates when this is true; paused/completed/failed cards
    /// sit quietly.
    var isRunning: Bool {
        resolvedState == .running
    }

    /// True if this snapshot represents a terminal run (the iOS Live
    /// Activity manager uses this to decide whether to end the activity
    /// instead of just updating it).
    var isTerminal: Bool {
        switch resolvedState {
        case .completed, .failed: return true
        case .paused, .running: return false
        }
    }

    /// Human-readable status line for the todo card subtitle. We prefer
    /// the title alone — it's already shaped for that surface — and fall
    /// back to `detail` if the runner only wrote a generic "Thinking"
    /// title without context.
    var cardStatusText: String {
        title
    }

    /// Recent step stack the detail card and widget render as the
    /// "previous intents" trail. Empty when the runner hasn't yet
    /// accumulated history (very first event of a run).
    var recentSteps: [AgentActivityStep] {
        guard let steps = payload?.objectValue?["steps"]?.arrayValue else {
            return []
        }
        return steps.compactMap(AgentActivityStep.init(json:))
    }
}

/// Phases the iOS UI recognizes. Anything else lands on `.unknown` which
/// the card / widget treat as a generic "Working…" line — but the runner
/// only ever writes these values in practice (see `runner/activity.py`).
enum AgentActivityPhase: String, Codable, Hashable, Sendable {
    case preparing
    case starting
    case thinking
    case tool
    case tool_done
    case final
    case idle
    case completed
    case failed
    case ready
    case needs_input
    case needs_auth
    case cancelled
    case unknown
}

enum AgentActivityState: String, Codable, Hashable, Sendable {
    case running
    case paused
    case completed
    case failed
}

/// Coarse tool category used to pick an SF Symbol on iOS. Keep in sync
/// with `_TOOL_CATEGORY_HINTS` in `runner/runner/activity.py`. Unknown
/// values fall through to `.unknown` which renders a generic tool icon.
enum AgentToolCategory: String, Codable, Hashable, Sendable {
    case gmail
    case calendar
    case sheets
    case docs
    case drive
    case notion
    case slack
    case audio
    case oauth
    case search
    case browser
    case thinking
    case question
    case final
    case error
    case instacart
    case twitter
    case reddit
    case unknown

    /// SF Symbol name for the activity row / widget icon. Picked to read
    /// well at 20pt in the Chowder-style row layout.
    var symbolName: String {
        switch self {
        case .gmail: return "envelope.fill"
        case .calendar: return "calendar"
        case .sheets: return "tablecells"
        case .docs: return "doc.text.fill"
        case .drive: return "externaldrive.fill"
        case .notion: return "book.closed.fill"
        case .slack: return "number"
        case .audio: return "waveform"
        case .oauth: return "key.fill"
        case .search: return "magnifyingglass"
        case .browser: return "safari"
        case .thinking: return "sparkles"
        case .question: return "questionmark.bubble.fill"
        case .final: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .instacart: return "cart.fill"
        case .twitter: return "bird.fill"
        case .reddit: return "newspaper.fill"
        case .unknown: return "wrench.and.screwdriver.fill"
        }
    }
}

/// One entry in the activity history surfaced by the widget / detail card.
/// Decoded from the `payload.steps` JSON array on `todo_agent_activity`.
struct AgentActivityStep: Hashable, Sendable, Identifiable {
    var id: String { "\(started_at.timeIntervalSince1970)-\(title)" }
    let title: String
    let detail: String?
    let tool_name: String?
    let tool_category: AgentToolCategory
    let started_at: Date
    let completed_at: Date?

    var isCompleted: Bool { completed_at != nil }

    init?(json: JSONValue) {
        guard let obj = json.objectValue else { return nil }
        guard let title = obj["title"]?.stringValue, !title.isEmpty else {
            return nil
        }
        self.title = title
        self.detail = obj["detail"]?.stringValue
        self.tool_name = obj["tool_name"]?.stringValue
        if let raw = obj["tool_category"]?.stringValue,
           let cat = AgentToolCategory(rawValue: raw) {
            self.tool_category = cat
        } else {
            self.tool_category = .unknown
        }
        self.started_at = Self.parseTimestamp(obj["started_at"]) ?? Date()
        self.completed_at = Self.parseTimestamp(obj["completed_at"])
    }

    private static func parseTimestamp(_ value: JSONValue?) -> Date? {
        guard let raw = value?.stringValue, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
