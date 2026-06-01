import Foundation

/// Wraps todo- or cron-scoped interactions so the shared chat thread can
/// render either without duplicating the interaction UI.
enum ChatInteractionEnvelope: Identifiable, Hashable, Sendable {
    case todo(TodoInteraction)
    case cron(CronJobInteraction)

    var id: UUID {
        switch self {
        case .todo(let i): return i.id
        case .cron(let i): return i.id
        }
    }

    var prompt: String {
        switch self {
        case .todo(let i): return i.prompt
        case .cron(let i): return i.prompt
        }
    }

    var status: InteractionStatus {
        switch self {
        case .todo(let i): return i.status
        case .cron(let i): return i.status
        }
    }

    var options: [InteractionOption] {
        switch self {
        case .todo(let i): return i.options
        case .cron(let i): return i.options
        }
    }

    var emailDraft: (subject: String, body: String, to: [String])? {
        switch self {
        case .todo(let i): return i.emailDraft
        case .cron(let i): return i.emailDraft
        }
    }

    var content: JSONValue? {
        switch self {
        case .todo(let i): return i.content
        case .cron(let i): return i.content
        }
    }

    var allowsFreeform: Bool {
        switch self {
        case .todo(let i): return i.allowsFreeform
        case .cron(let i): return i.allowsFreeform
        }
    }

    var freeformPlaceholder: String? {
        switch self {
        case .todo(let i): return i.freeformPlaceholder
        case .cron(let i): return i.freeformPlaceholder
        }
    }

    var respondedBubbleText: String? {
        switch self {
        case .todo(let i): return i.respondedBubbleText
        case .cron(let i): return i.respondedBubbleText
        }
    }

    var responded_at: Date? {
        switch self {
        case .todo(let i): return i.responded_at
        case .cron(let i): return i.responded_at
        }
    }

    var updated_at: Date {
        switch self {
        case .todo(let i): return i.updated_at
        case .cron(let i): return i.updated_at
        }
    }

    var summary: String? {
        switch self {
        case .todo(let i): return i.summary
        case .cron(let i): return i.summary
        }
    }
}
