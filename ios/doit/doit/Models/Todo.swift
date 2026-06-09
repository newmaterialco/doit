import Foundation

enum TodoStatus: String, Codable, Sendable, CaseIterable {
    case preparing
    case todo
    case requested
    case running
    case needs_auth
    case needs_input
    case done
    case failed
    case cancelled

    /// Short, colloquial labels surfaced in the detail view header. The
    /// runner has finer-grained internal states (`preparing`, `requested`,
    /// `running`) but they all collapse to "Doing" here — users only care
    /// that something is in flight, not which sub-phase.
    var label: String {
        switch self {
        case .todo: return "Todo"
        case .preparing, .requested, .running: return "Doing"
        case .needs_auth, .needs_input: return "Waiting for you…"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isActive: Bool {
        self == .requested || self == .running || self == .preparing
    }

    /// Statuses where the user can still cancel the agent's work. We treat
    /// "waiting on you" states as cancellable so the Stop button stays useful
    /// when the agent has paused for OAuth or an input prompt. The preparation
    /// pass is also cancellable so a stuck spinner is never a dead end.
    var isCancellable: Bool {
        isActive || self == .needs_auth || self == .needs_input
    }
}

enum TodoTopic: String, Codable, Sendable, CaseIterable, Identifiable {
    case communication
    case scheduling
    case research
    case documents
    case coding
    case finance
    case shopping
    case travel
    case personal
    case work
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .communication: return "Communication"
        case .scheduling: return "Scheduling"
        case .research: return "Research"
        case .documents: return "Documents"
        case .coding: return "Coding"
        case .finance: return "Finance"
        case .shopping: return "Shopping"
        case .travel: return "Travel"
        case .personal: return "Personal"
        case .work: return "Work"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .communication: return "bubble.left.and.bubble.right.fill"
        case .scheduling: return "calendar.badge.clock"
        case .research: return "magnifyingglass"
        case .documents: return "doc.text.fill"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .finance: return "dollarsign.circle.fill"
        case .shopping: return "cart.fill"
        case .travel: return "airplane"
        case .personal: return "person.crop.circle.fill"
        case .work: return "briefcase.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }
}

struct Todo: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let user_id: UUID
    var title: String
    var detail: String?
    var status: TodoStatus
    var hermes_run_id: String?
    var hermes_session_id: String?
    var error_message: String?
    /// The user's raw input, preserved before the preparation pass rewrites
    /// `title` into a concise version.
    var original_title: String?
    /// Composio toolkit slug the agent expects to use (e.g. "gmail",
    /// "googlecalendar"). Drives the small connection icon on the card.
    var connection_slug: String?
    /// Short human-readable summary of what the agent plans to do, written
    /// during the preparation phase.
    var preparation_summary: String?
    /// Lifetime sum of LLM tokens consumed by this todo across every run /
    /// rerun. Populated by the runner from Hermes' per-turn `usage` blocks
    /// on the SSE stream (and reconciled against `GET /v1/runs/{id}` once
    /// each run ends). Optional so older rows decode cleanly; treat nil as 0.
    var total_tokens: Int64?
    /// User-controlled pin for important completed tasks.
    var is_starred: Bool
    /// Broad category assigned during preparation. Unknown / missing values
    /// fall back to `other` at the UI layer.
    var topic: String?
    /// Optional durable grouping for projects, companies, clients, or events.
    var collection_name: String?
    let created_at: Date
    let updated_at: Date
    var completed_at: Date?

    var effectiveTopic: TodoTopic {
        topic.flatMap(TodoTopic.init(rawValue:)) ?? .other
    }

    var normalizedCollectionName: String? {
        let trimmed = collection_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Insert payload for a new todo. The DB fills in `id`, `user_id` (via RLS check),
/// `created_at`, `updated_at`. New todos enter `preparing` so the runner can
/// rephrase the title and pick a likely connection. On success the runner
/// flips the same row to `requested` and the agent starts working
/// automatically — there is no manual "Do it" tap in front of the
/// auto-run flow.
struct NewTodo: Encodable, Sendable {
    let user_id: UUID
    let title: String
    let detail: String?
    let status: TodoStatus
    let original_title: String
    /// IANA timezone identifier (e.g. `America/Los_Angeles`) reported by the
    /// device when this todo was created. The runner uses this to set the
    /// timezone of any cron job promoted from this todo, so a "9 AM daily"
    /// schedule fires at 9 AM in the location the user typed it — and stays
    /// pinned to that location even if they later travel.
    let client_timezone: String?
}

enum StepKind: String, Codable, Sendable {
    case thought
    case tool_started
    case tool_result
    case oauth_needed
    case input_needed
    case final
    case error
}

struct TodoStep: Codable, Identifiable, Hashable, Sendable {
    let id: Int64
    let todo_id: UUID
    let user_id: UUID
    let ts: Date
    let kind: StepKind
    let text: String?
    let url: String?
    let tool_name: String?

    var containsInteractionMarker: Bool {
        text?.contains("[[DOIT_INTERACTION]]") == true
            || text?.contains("[[/DOIT_INTERACTION]]") == true
    }
}

// MARK: - Interactions

enum InteractionKind: String, Codable, Sendable {
    case approval
    case choice
    case question
    case confirmation
}

enum InteractionStatus: String, Codable, Sendable {
    case open
    case responded
    case cancelled
    case superseded
}

enum InteractionStyle: String, Codable, Sendable {
    case primary
    case secondary
    case destructive
}

/// Loose JSON value used for the interaction `payload` and `response` jsonb
/// columns. The schemas inside are conventional, not enforced.
indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v); return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Numeric accessor used by artifact payloads that carry sizes /
    /// durations (e.g. audio clips). Falls through to a parsed string for
    /// JSON producers that emit numbers as strings.
    var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

struct InteractionOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    let style: InteractionStyle?
}

struct TodoInteraction: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let todo_id: UUID
    let user_id: UUID
    let hermes_run_id: String?
    let kind: InteractionKind
    /// `var` so the detail view can flip an interaction from `.open` →
    /// `.responded` optimistically the instant the user taps a quick
    /// reply or sends a freeform answer; realtime then reconciles with
    /// the row the server persisted.
    var status: InteractionStatus
    let prompt: String
    let payload: JSONValue?
    var response: JSONValue?
    let created_at: Date
    let updated_at: Date
    var responded_at: Date?

    var summary: String? {
        payload?.objectValue?["summary"]?.stringValue
    }

    /// Preparation-phase interactions are clarifications the agent asked
    /// before the user has approved execution. The iOS app uses this to
    /// route the user's response back to `preparing` (not `requested`) so
    /// the runner can re-prepare instead of immediately running the task.
    var isPreparationPhase: Bool {
        (payload?.objectValue?["phase"]?.stringValue ?? "") == "prepare"
    }

    var content: JSONValue? {
        payload?.objectValue?["content"]
    }

    var allowsFreeform: Bool {
        payload?.objectValue?["allow_freeform"]?.boolValue ?? false
    }

    var freeformPlaceholder: String? {
        payload?.objectValue?["freeform_placeholder"]?.stringValue
    }

    var options: [InteractionOption] {
        guard let raw = payload?.objectValue?["options"]?.arrayValue else { return [] }
        return raw.compactMap { value in
            guard let obj = value.objectValue else { return nil }
            guard let id = obj["id"]?.stringValue,
                  let label = obj["label"]?.stringValue else { return nil }
            let style = obj["style"]?.stringValue.flatMap(InteractionStyle.init(rawValue:))
            return InteractionOption(id: id, label: label, style: style)
        }
    }

    /// The option id the user selected (if any). Available once
    /// `status != .open`; comes back as `nil` for pure freeform replies.
    var respondedOptionID: String? {
        response?.objectValue?["option_id"]?.stringValue
    }

    /// Freeform text the user typed (if any). Available once
    /// `status != .open` and the response carried text.
    var respondedText: String? {
        let raw = response?.objectValue?["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Human-readable summary of the user's reply, ready to drop into a
    /// chat bubble: the matching option's label when they picked one,
    /// otherwise the freeform text, otherwise `nil` (e.g. cancelled
    /// without a recorded answer).
    var respondedBubbleText: String? {
        if let id = respondedOptionID,
           let label = options.first(where: { $0.id == id })?.label {
            if let extra = respondedText {
                return "\(label) — \(extra)"
            }
            return label
        }
        return respondedText
    }

    /// `content.subject` + `content.body` for email-style drafts. Returns nil if
    /// the payload doesn't look like a structured draft.
    var emailDraft: (subject: String, body: String, to: [String])? {
        guard let obj = content?.objectValue else { return nil }
        guard let subject = obj["subject"]?.stringValue,
              let body = obj["body"]?.stringValue else { return nil }
        let to = obj["to"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        return (subject: subject, body: body, to: to)
    }
}

struct InteractionResponsePatch: Encodable, Sendable {
    let status: String
    let response: InteractionResponse
}

struct InteractionResponse: Encodable, Sendable {
    let option_id: String?
    let text: String?
}

enum MemoryTarget: String, Codable, Sendable, CaseIterable {
    case user
    case memory

    var label: String {
        switch self {
        case .user: return "About you"
        case .memory: return "Agent notes"
        }
    }

    var hint: String {
        switch self {
        case .user:
            return "Preferences, identity, communication style. Lands in USER.md."
        case .memory:
            return "Workflow facts, conventions, lessons the agent should keep. Lands in MEMORY.md."
        }
    }
}

enum MemorySource: String, Codable, Sendable {
    case user
    case hermes
    case doit

    var label: String {
        switch self {
        case .user: return "Pinned"
        case .hermes: return "Learned by agent"
        case .doit: return "Learned by Doit"
        }
    }
}

enum MemorySyncStatus: String, Codable, Sendable {
    case pending
    case synced
    case failed
}

enum MemoryLifecycleStatus: String, Codable, Sendable {
    case proposed
    case active
    case rejected
    case deleted

    var label: String {
        switch self {
        case .proposed: return "Suggested"
        case .active: return "Active"
        case .rejected: return "Rejected"
        case .deleted: return "Forgotten"
        }
    }
}

enum MemoryConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

struct AgentMemory: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let user_id: UUID
    var title: String
    var body: String
    var category: String?
    var target: MemoryTarget?
    var source: MemorySource?
    var sync_status: MemorySyncStatus?
    var memory_status: MemoryLifecycleStatus?
    var memory_confidence: MemoryConfidence?
    var memory_reason: String?
    var source_todo_id: UUID?
    var reviewed_at: Date?
    var sync_error: String?
    var last_sync_at: Date?
    let created_at: Date
    let updated_at: Date

    var effectiveTarget: MemoryTarget { target ?? .user }
    var effectiveSource: MemorySource { source ?? .user }
    var effectiveSyncStatus: MemorySyncStatus { sync_status ?? .pending }
    var effectiveMemoryStatus: MemoryLifecycleStatus { memory_status ?? .active }
    var isVisibleMemory: Bool { effectiveMemoryStatus != .deleted }
    var isSuggestedMemory: Bool { effectiveMemoryStatus == .proposed }
    var isActiveMemory: Bool { effectiveMemoryStatus == .active }
}

struct NewAgentMemory: Encodable, Sendable {
    let user_id: UUID
    let title: String
    let body: String
    let category: String?
    let target: String?
}

struct MemorySettings: Codable, Sendable {
    let user_id: UUID
    var automatic_suggestions_enabled: Bool
    var custom_instructions: String?
    let created_at: Date?
    let updated_at: Date?
}
