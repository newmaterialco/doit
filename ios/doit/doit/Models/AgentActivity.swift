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

    /// Most human-facing one-liner for what Hermes is doing right now.
    /// The runner's `detail` can be a useful activity sentence, but it
    /// can also be a raw tool preview/output (`set -e ...`, JSON, `*`).
    /// Only promote it when it reads like user-facing prose; otherwise
    /// synthesize a calmer activity label from the tool-call title.
    var humanActivityText: String {
        if let detail = AgentActivityCopy.readableDetail(detail) {
            return detail
        }
        return AgentActivityCopy.friendlyFallback(for: title, category: resolvedCategory)
    }

    /// Canonical prominent status text for every in-app and ActivityKit
    /// surface. Kept separate from `humanActivityText` so call sites can
    /// read intent instead of re-deciding which field is primary.
    var primaryStatusText: String {
        humanActivityText
    }

    /// Compact tool-call indicator shown alongside the human-facing
    /// detail in the Live Activity / Dynamic Island. Always the runner
    /// `title` so the user can still see *which* tool the agent is
    /// using even when the prominent line is the more verbose detail.
    var toolCallText: String {
        title
    }

    /// Canonical secondary label for compact technical context. Hidden by
    /// surfaces when it is identical to the primary line.
    var secondaryToolText: String {
        toolCallText
    }

    /// Visible-content signature for animation identity. This deliberately
    /// excludes `updated_at` so heartbeat / REST-refresh duplicates don't
    /// reinsert the same detail-header card over and over.
    var activityContentSignature: String {
        [
            phase,
            state,
            primaryStatusText,
            secondaryToolText,
            tool_name ?? "",
            tool_category ?? ""
        ].joined(separator: "|")
    }

    /// Refresh signature shared by list rows and other surfaces that need to
    /// redraw when the row is refreshed, even if visible copy is unchanged.
    var activitySignature: String {
        [
            activityContentSignature,
            updated_at.ISO8601Format()
        ].joined(separator: "|")
    }

    /// Human-readable status line for the todo card subtitle.
    var cardStatusText: String {
        primaryStatusText
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
    case figma
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
        case .figma: return "paintpalette.fill"
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

    /// Detail-first copy mirroring `AgentActivity.humanActivityText` so
    /// the previous-intent stack reads the same way as the current one.
    var humanActivityText: String {
        if let detail = AgentActivityCopy.readableDetail(detail) {
            return detail
        }
        return AgentActivityCopy.friendlyFallback(for: title, category: tool_category)
    }

    var primaryStatusText: String {
        humanActivityText
    }

    /// Compact tool-call label for surfaces that want both fields
    /// (Live Activity / Dynamic Island).
    var toolCallText: String {
        title
    }

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

private enum AgentActivityCopy {
    static func readableDetail(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !looksLikeToolNoise(text) else {
            return nil
        }
        return text
    }

    static func friendlyFallback(for title: String, category: AgentToolCategory) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()

        if lower.contains("terminal") || lower.contains("shell") || lower.contains("command") {
            if lower.hasPrefix("review") || lower.contains("completed") {
                return "Checking the command result"
            }
            return "Working in the project"
        }
        if lower.contains("read") {
            return lower.hasPrefix("review") ? "Reviewing project files" : "Reading project files"
        }
        if lower.contains("skill") {
            return lower.hasPrefix("review") ? "Reviewing project guidance" : "Checking project guidance"
        }

        switch category {
        case .browser:
            return lower.hasPrefix("review") ? "Reading the web result" : "Reading from the web"
        case .search:
            return lower.hasPrefix("review") ? "Reviewing search results" : "Searching for information"
        case .gmail:
            return lower.hasPrefix("review") ? "Reviewing Gmail results" : "Working with Gmail"
        case .calendar:
            return lower.hasPrefix("review") ? "Reviewing calendar results" : "Working with the calendar"
        case .sheets:
            return lower.hasPrefix("review") ? "Reviewing spreadsheet changes" : "Working on a spreadsheet"
        case .docs:
            return lower.hasPrefix("review") ? "Reviewing document changes" : "Working on a document"
        case .drive:
            return lower.hasPrefix("review") ? "Reviewing Drive results" : "Working with Drive"
        case .slack:
            return lower.hasPrefix("review") ? "Reviewing Slack results" : "Working in Slack"
        case .notion:
            return lower.hasPrefix("review") ? "Reviewing Notion results" : "Working in Notion"
        case .audio:
            return "Preparing the audio"
        case .oauth:
            return "Checking the account connection"
        case .thinking:
            return "Thinking through the next step"
        case .question:
            return "Waiting for your reply"
        case .final:
            return "Wrapping up"
        case .error:
            return "Checking what went wrong"
        case .instacart:
            return "Working with Instacart"
        case .twitter:
            return "Working with Twitter"
        case .reddit:
            return "Working with Reddit"
        case .figma:
            return lower.hasPrefix("review") ? "Reviewing Figma results" : "Working in Figma"
        case .unknown:
            if cleaned.isEmpty || lower.hasPrefix("using ") || lower.hasPrefix("reviewing ") {
                return "Working on the task"
            }
            return cleaned
        }
    }

    private static func looksLikeToolNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if trimmed.count < 4 { return true }
        if trimmed == "*" || trimmed == "-" || trimmed == "..." { return true }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.contains("```") { return true }
        if lower.hasPrefix("tool completed") || lower.hasPrefix("tool hit an issue") {
            return true
        }
        if lower.range(of: #"^\w+(?:[-_]\w+)+$"#, options: .regularExpression) != nil {
            return true
        }

        let commandPrefixes = [
            "set -", "rm ", "git ", "cd ", "mkdir ", "cp ", "mv ", "curl ",
            "python ", "python3 ", "npm ", "pnpm ", "yarn ", "swift ",
            "xcodebuild ", "sed ", "awk ", "grep ", "rg ", "cat ", "ls "
        ]
        if commandPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let codeMarkers = ["&&", " || ", " --", " -e ", "#!/", "frompath=", "path="]
        if codeMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let proseCharacters = trimmed.filter { $0.isLetter || $0 == " " || $0 == "." || $0 == "," }
        let proseRatio = Double(proseCharacters.count) / Double(max(trimmed.count, 1))
        return proseRatio < 0.55
    }
}
