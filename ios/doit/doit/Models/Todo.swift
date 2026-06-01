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
    let created_at: Date
    let updated_at: Date
    var completed_at: Date?
}

/// Insert payload for a new todo. The DB fills in `id`, `user_id` (via RLS check),
/// `created_at`, `updated_at`. New todos enter `preparing` so the runner can
/// rephrase the title and pick a likely connection before the user is asked
/// to tap "Do it".
struct NewTodo: Encodable, Sendable {
    let user_id: UUID
    let title: String
    let detail: String?
    let status: TodoStatus
    let original_title: String
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

    var label: String {
        switch self {
        case .user: return "Pinned"
        case .hermes: return "Learned by agent"
        }
    }
}

enum MemorySyncStatus: String, Codable, Sendable {
    case pending
    case synced
    case failed
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
    var sync_error: String?
    var last_sync_at: Date?
    let created_at: Date
    let updated_at: Date

    var effectiveTarget: MemoryTarget { target ?? .user }
    var effectiveSource: MemorySource { source ?? .user }
    var effectiveSyncStatus: MemorySyncStatus { sync_status ?? .pending }
}

struct NewAgentMemory: Encodable, Sendable {
    let user_id: UUID
    let title: String
    let body: String
    let category: String?
    let target: String?
}
