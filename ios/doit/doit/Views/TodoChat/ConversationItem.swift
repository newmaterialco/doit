import Foundation

/// A single rendered message in the todo's chat thread. Built by merging the
/// task's source-of-truth records (original request, attachments, agent
/// steps, agent interactions, error) into a chronological-ish list the chat
/// view can iterate over.
enum ConversationItem: Identifiable, Hashable {
    case userRequest(text: String, ts: Date)
    case userAttachments(ids: [UUID])
    case userMessage(id: UUID, text: String, ts: Date)
    case agentStep(TodoStep)
    case agentThinking(label: String)
    case agentInteraction(ChatInteractionEnvelope)
    case agentError(text: String)
    /// Bubble rendered when the runner has prepped the task and is
    /// parked at `status == .todo` waiting for the user to confirm.
    /// Carries the optional preparation summary so the bubble can
    /// describe what's about to happen ("I'll create a calendar invite…")
    /// before the user taps the inline "Do it" button.
    case agentReadyToRun(summary: String?)

    var id: String {
        switch self {
        case .userRequest:
            return "user-request"
        case .userAttachments(let ids):
            return "user-attachments-\(ids.map(\.uuidString).joined(separator: "-"))"
        case .userMessage(let id, _, _):
            return "user-message-\(id.uuidString)"
        case .agentStep(let step):
            return "step-\(step.id)"
        case .agentThinking:
            // Constant id so SwiftUI keeps the same view instance across
            // label changes and the contentTransition can crossfade.
            return "agent-thinking"
        case .agentInteraction(let interaction):
            return "interaction-\(interaction.id.uuidString)"
        case .agentError(let text):
            return "error-\(text.hashValue)"
        case .agentReadyToRun:
            // Single live instance — the prompt is identical regardless
            // of summary changes, and a stable id lets SwiftUI animate
            // the button state without rebuilding the row.
            return "agent-ready-to-run"
        }
    }
}

enum ConversationBuilder {
    /// Produces the ordered message list rendered in the chat thread.
    ///
    /// Order:
    ///   1. The user's original request (preserved before the preparation
    ///      pass rewrites `title`).
    ///   2. Attachments uploaded with the task, grouped into one bubble.
    ///   3. Agent activity — only the actionable / final steps make it
    ///      into the chat: `final` (the assistant's reply) and
    ///      `oauth_needed` (carries the auth link button). Intermediate
    ///      `thought` / `tool_started` / `tool_result` steps are dropped
    ///      from the timeline by design — they were noisy to read.
    ///   4. Every interaction the agent has opened on this todo, in
    ///      timestamp order. Open ones render with their option
    ///      buttons; closed ones stay as static history with the user's
    ///      reply synthesised as a user bubble right after.
    ///   5. While the agent is mid-flight (status active and no `final`
    ///      step yet), a single light-grey "Thinking…" line stands in
    ///      for all the hidden activity.
    ///   6. A "Ready to do this" bubble with an inline "Do it" button
    ///      when the runner has prepared the task and is parked at
    ///      `status == .todo` waiting for the user's go-ahead.
    ///   7. A trailing error bubble if the task has one.
    static func build(
        todo: Todo,
        steps: [TodoStep],
        interactions: [TodoInteraction],
        attachments: [TodoAttachment],
        messages: [TodoMessage],
        error: String?
    ) -> [ConversationItem] {
        var items: [ConversationItem] = []

        let request = (todo.original_title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? todo.title
        items.append(.userRequest(text: request, ts: todo.created_at))

        if !attachments.isEmpty {
            items.append(.userAttachments(ids: attachments.map(\.id)))
        }

        let visibleSteps = steps.filter { step in
            guard !step.containsInteractionMarker else { return false }
            switch step.kind {
            case .final, .oauth_needed:
                return true
            case .thought, .tool_started, .tool_result, .input_needed, .error:
                return false
            }
        }

        struct Dated {
            let item: ConversationItem
            let ts: Date
            /// Sub-order on tie: lower sorts earlier. Used so a closed
            /// interaction (the question) sits immediately above the
            /// synthesised reply bubble that shares its `responded_at`.
            let tiebreaker: Int
        }
        var dated: [Dated] = visibleSteps.map {
            Dated(item: .agentStep($0), ts: $0.ts, tiebreaker: 1)
        }
        for message in messages {
            dated.append(Dated(
                item: .userMessage(id: message.id, text: message.body, ts: message.created_at),
                ts: message.created_at,
                tiebreaker: 0
            ))
        }
        for interaction in interactions {
            dated.append(Dated(
                item: .agentInteraction(.todo(interaction)),
                ts: interaction.created_at,
                tiebreaker: 1
            ))
            // Closed interactions: turn the user's recorded answer into
            // a regular chat bubble anchored to `responded_at`, so the
            // transcript reads as Q&A. We reuse `.userMessage` (keyed by
            // the interaction id) so the bubble visually matches every
            // other user-side message.
            if interaction.status != .open,
               let reply = interaction.respondedBubbleText,
               !reply.isEmpty {
                let replyTs = interaction.responded_at ?? interaction.updated_at
                dated.append(Dated(
                    item: .userMessage(id: interaction.id, text: reply, ts: replyTs),
                    ts: replyTs,
                    tiebreaker: 2
                ))
            }
        }
        dated.sort { lhs, rhs in
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            if lhs.tiebreaker != rhs.tiebreaker { return lhs.tiebreaker < rhs.tiebreaker }
            return lhs.item.userTurnPriority < rhs.item.userTurnPriority
        }
        items.append(contentsOf: dated.map(\.item))

        let openInteraction = interactions.last(where: { $0.status == .open })

        // Show the thinking placeholder only when the agent is
        // genuinely working — paused-for-input / paused-for-auth runs
        // don't double up with the actionable card. The check is
        // "no final step *since the latest user turn*" so the
        // placeholder reappears on multi-turn chats after a follow-up.
        let latestUserTurn: Date = {
            var candidates: [Date] = [todo.created_at]
            candidates.append(contentsOf: messages.map(\.created_at))
            for interaction in interactions where interaction.status != .open {
                if let ts = interaction.responded_at {
                    candidates.append(ts)
                }
            }
            return candidates.max() ?? todo.created_at
        }()
        let hasRecentFinalStep = visibleSteps.contains { step in
            step.kind == .final && step.ts >= latestUserTurn
        }
        if todo.status.isActive && !hasRecentFinalStep && openInteraction == nil {
            let latestActivity = steps
                .filter { !$0.containsInteractionMarker }
                .filter { $0.kind == .thought || $0.kind == .tool_started || $0.kind == .tool_result }
                .max(by: { $0.ts < $1.ts })
            items.append(.agentThinking(label: thinkingLabel(for: latestActivity)))
        }

        // Ready-to-run card: the runner parks a prepped task at
        // `status == .todo` until the user confirms. Surfacing the Do-it
        // button right in the chat lets them confirm without bouncing
        // back to the task list.
        if todo.status == .todo && openInteraction == nil {
            let summary = todo.preparation_summary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(.agentReadyToRun(summary: (summary?.isEmpty == false) ? summary : nil))
        }

        if let error, !error.isEmpty {
            items.append(.agentError(text: error))
        }

        return items
    }
}

private extension ConversationItem {
    /// Tie-breaker used when sorting by timestamp. User-side items render
    /// before agent-side items on the same instant so an optimistic local
    /// message sits above the immediately-following agent activity.
    var userTurnPriority: Int {
        switch self {
        case .userRequest, .userAttachments, .userMessage:
            return 0
        case .agentStep, .agentThinking, .agentInteraction, .agentError, .agentReadyToRun:
            return 1
        }
    }
}

/// Maps the latest in-flight agent step to a short, present-tense status
/// line for the chat thread's placeholder. Hidden behind the builder so
/// other call sites that don't care about chat copy don't need to know
/// about Hermes' tool naming conventions.
private func thinkingLabel(for step: TodoStep?) -> String {
    guard let step else { return "Thinking…" }
    switch step.kind {
    case .tool_started:
        if let tool = step.tool_name?.trimmingCharacters(in: .whitespaces),
           !tool.isEmpty {
            return "Working on \(humanizeToolName(tool))…"
        }
        return "Working…"
    case .tool_result:
        if let tool = step.tool_name?.trimmingCharacters(in: .whitespaces),
           !tool.isEmpty {
            return "Reviewing \(humanizeToolName(tool)) result…"
        }
        return "Reviewing results…"
    case .thought:
        return "Thinking…"
    default:
        return "Thinking…"
    }
}

/// Humanizes a Hermes/Composio tool identifier like
/// `COMPOSIO_GMAIL_SEND_EMAIL` into a readable phrase like
/// `Gmail send email`. Strips the noisy provider prefixes the runner
/// surfaces verbatim and lower-cases the result so it reads naturally
/// inside a sentence ("Working on gmail send email…").
private func humanizeToolName(_ raw: String) -> String {
    var s = raw
    for prefix in ["COMPOSIO_", "MCP_", "HERMES_"] {
        if s.uppercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
    }
    let spaced = s.replacingOccurrences(of: "_", with: " ").lowercased()
    // Capitalize the first character only — keeps the rest natural ("gmail
    // send email" → "Gmail send email") instead of title-casing every word.
    guard let first = spaced.first else { return spaced }
    return first.uppercased() + spaced.dropFirst()
}
