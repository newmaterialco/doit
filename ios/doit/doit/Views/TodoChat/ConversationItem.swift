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
    case agentConfirmation(id: String, text: String, ts: Date)
    case agentInteraction(ChatInteractionEnvelope)
    case agentError(text: String)
    /// Bubble rendered when the runner has prepped the task and is
    /// parked at `status == .todo` waiting for the user to confirm.
    /// Carries the optional preparation summary so the bubble can
    /// describe what's about to happen ("I'll create a calendar invite…")
    /// before the user taps the inline "Do it" button.
    case agentReadyToRun(summary: String?)
    /// Agent-produced deliverable anchored below the final reply for
    /// the turn that emitted it. Header cards use the same artifact rows.
    case agentArtifact(TodoArtifact)

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
        case .agentConfirmation(let id, _, _):
            return "agent-confirmation-\(id)"
        case .agentInteraction(let interaction):
            return "interaction-\(interaction.id.uuidString)"
        case .agentError(let text):
            return "error-\(text.hashValue)"
        case .agentReadyToRun:
            // Single live instance — the prompt is identical regardless
            // of summary changes, and a stable id lets SwiftUI animate
            // the button state without rebuilding the row.
            return "agent-ready-to-run"
        case .agentArtifact(let artifact):
            return "artifact-\(artifact.id.uuidString)"
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
    ///   3. Everything else — agent finals/oauth, follow-up messages,
    ///      interactions, and synthesised replies — sorted by timestamp.
    ///   4. While the agent is mid-flight, a "Thinking…" placeholder.
    ///   5. Ready-to-run / error bubbles at the end when applicable.
    static func build(
        todo: Todo,
        steps: [TodoStep],
        interactions: [TodoInteraction],
        attachments: [TodoAttachment],
        messages: [TodoMessage],
        artifacts: [TodoArtifact] = [],
        error: String?,
        agentActivity: AgentActivity? = nil
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
        dated.append(contentsOf: artifactTimelineEntries(artifacts: artifacts, steps: steps))
        dated.sort { lhs, rhs in
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            if lhs.tiebreaker != rhs.tiebreaker { return lhs.tiebreaker < rhs.tiebreaker }
            let lhsKey = lhs.item.artifactSortKey
            let rhsKey = rhs.item.artifactSortKey
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.item.userTurnPriority < rhs.item.userTurnPriority
        }
        items.append(contentsOf: dated.map(\.item))

        let openInteraction = interactions.last(where: { $0.status == .open })

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
            // The live `AgentActivity` snapshot is the most accurate
            // source of "what is the agent doing right now?" and uses
            // the runner's human-facing detail copy ("Looking up flights
            // from SFO to JFK on Tuesday") when available. We only fall
            // back to the older `todo_steps` derivation when no live
            // snapshot has landed yet — typically the first beat of a
            // run before the runner upserts `todo_agent_activity`.
            if let activity = agentActivity,
               let label = thinkingLabel(for: activity, todoIsActive: todo.status.isActive) {
                items.append(.agentThinking(label: label))
            } else {
                let latestActivity = steps
                    .filter { !$0.containsInteractionMarker }
                    .filter { $0.kind == .thought || $0.kind == .tool_started || $0.kind == .tool_result }
                    .max(by: { $0.ts < $1.ts })
                items.append(.agentThinking(label: thinkingLabel(for: latestActivity)))
            }
        }

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

    /// Places deduplicated artifact cards immediately after the agent
    /// final reply for the turn that produced them. Artifacts are
    /// persisted shortly before or after the deferred final step insert,
    /// but unmatched artifacts stay header-only until a final arrives so
    /// the chat never looks done while the runner is still active.
    private static func artifactTimelineEntries(
        artifacts: [TodoArtifact],
        steps: [TodoStep]
    ) -> [Dated] {
        let grouped = TodoArtifact.groupedForDisplay(artifacts)
        let deduped = grouped.primary + grouped.emailDrafts
        guard !deduped.isEmpty else { return [] }

        let finalSteps = steps
            .filter { !$0.containsInteractionMarker && $0.kind == .final }
            .sorted { $0.ts < $1.ts }

        let finalSlack: TimeInterval = 30

        func windowStart(for index: Int) -> Date {
            if index == 0 { return .distantPast }
            return finalSteps[index - 1].ts.addingTimeInterval(finalSlack)
        }

        var dated: [Dated] = []
        for artifact in deduped {
            var matchedFinal: TodoStep?
            for (index, final) in finalSteps.enumerated() {
                let start = windowStart(for: index)
                let end = final.ts.addingTimeInterval(finalSlack)
                if artifact.updated_at >= start && artifact.updated_at <= end {
                    matchedFinal = final
                }
            }
            if let final = matchedFinal {
                dated.append(Dated(
                    item: .agentArtifact(artifact),
                    ts: final.ts,
                    tiebreaker: 2
                ))
            }
        }
        return dated
    }

    private struct Dated {
        let item: ConversationItem
        let ts: Date
        /// Sub-order on tie: lower sorts earlier. Used so a closed
        /// interaction (the question) sits immediately above the
        /// synthesised reply bubble that shares its `responded_at`.
        let tiebreaker: Int
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
        case .agentStep, .agentThinking, .agentConfirmation, .agentInteraction,
             .agentError, .agentReadyToRun, .agentArtifact:
            return 1
        }
    }

    /// Stable sub-order for multiple artifact cards on the same turn.
    var artifactSortKey: String {
        if case .agentArtifact(let artifact) = self {
            return artifact.artifact_key
        }
        return ""
    }
}

// MARK: - Agent reply text

/// Normalizes agent reply copy before it hits the chat transcript.
enum AgentReplyText {
    private static let markers = [
        "[[DOIT_ARTIFACT]]", "[[/DOIT_ARTIFACT]]",
        "[[DOIT_INTERACTION]]", "[[/DOIT_INTERACTION]]",
        "[[DOIT_TASKS]]", "[[/DOIT_TASKS]]",
        "[[DOIT_ACTIVITY]]", "[[/DOIT_ACTIVITY]]",
    ]

    static func normalize(_ text: String) -> String {
        var cleaned = text
        for marker in markers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        cleaned = stripRawToolNoise(cleaned)
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        cleaned = collapseDoneLeadins(cleaned)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripRawToolNoise(_ text: String) -> String {
        let lower = text.lowercased()
        let noisyNeedles = [
            "nts to ", "<ctrl", "github_create_or_update_file_contents",
            "composio_", "default_api.", "<!doctype html", "<html"
        ]
        guard noisyNeedles.contains(where: { lower.contains($0) }) else {
            return text
        }
        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let l = line.lowercased()
                if line.isEmpty { return true }
                if noisyNeedles.contains(where: { l.contains($0) }) { return false }
                if line.hasPrefix("{") || line.hasPrefix("}") || line.hasPrefix("<") { return false }
                return true
            }
        return kept.joined(separator: "\n")
    }

    /// Fold repeated ``Done —`` openings into one paragraph (matches runner).
    private static func collapseDoneLeadins(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }
        let chunks = stripped.components(separatedBy: "\n\n")
        guard chunks.count > 1 else { return stripped }
        var merged: [String] = []
        for chunk in chunks {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if merged.isEmpty {
                merged.append(piece)
                continue
            }
            if hasDoneLeadIn(piece) {
                let body = stripDoneLeadIn(piece)
                if !body.isEmpty { merged.append(body) }
            } else {
                merged.append(piece)
            }
        }
        return merged.joined(separator: "\n\n")
    }

    private static func hasDoneLeadIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("done —") || lower.hasPrefix("done -")
    }

    private static func stripDoneLeadIn(_ text: String) -> String {
        if text.lowercased().hasPrefix("done —") {
            return String(text.dropFirst("done —".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.lowercased().hasPrefix("done -") {
            return String(text.dropFirst("done -".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
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

/// Maps the live `AgentActivity` snapshot to a chat-thread placeholder
/// label. We prefer the runner-provided human-facing detail copy
/// (matching the home card subtitle, detail-view cards, and Live
/// Activity widget) so every "what is the agent doing?" surface stays
/// in sync.
///
/// Returns `nil` when the snapshot isn't useful for a placeholder so
/// the caller can fall back to the older `todo_steps` derivation.
private func thinkingLabel(for activity: AgentActivity, todoIsActive: Bool) -> String? {
    if todoIsActive, !activity.isRunning, activity.resolvedState != .paused {
        if !activity.primaryStatusText.isEmpty {
            return activity.primaryStatusText
        }
        return "Getting started…"
    }
    guard activity.isRunning || activity.resolvedState == .paused else {
        return nil
    }
    let label = activity.primaryStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    if let secondary = activity.secondaryStatusText {
        return "\(label) — \(secondary)"
    }
    return label
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
    guard let first = spaced.first else { return spaced }
    return first.uppercased() + spaced.dropFirst()
}
