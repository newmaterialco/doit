import Foundation

enum CronConversationBuilder {
    static func build(
        job: CronJob,
        interactions: [CronJobInteraction],
        messages: [CronJobMessage]
    ) -> [ConversationItem] {
        var items: [ConversationItem] = []

        let request = (job.original_prompt?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? job.prompt
        items.append(.userRequest(text: request, ts: job.created_at))

        struct Dated {
            let item: ConversationItem
            let ts: Date
            let tiebreaker: Int
        }
        var dated: [Dated] = []

        for message in messages {
            dated.append(Dated(
                item: .userMessage(id: message.id, text: message.body, ts: message.created_at),
                ts: message.created_at,
                tiebreaker: 0
            ))
        }
        for interaction in interactions {
            dated.append(Dated(
                item: .agentInteraction(.cron(interaction)),
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
        dated.sort { lhs, rhs in
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            return lhs.tiebreaker < rhs.tiebreaker
        }
        items.append(contentsOf: dated.map(\.item))

        let openInteraction = interactions.last(where: { $0.status == .open })
        if job.state.isActive && openInteraction == nil {
            items.append(.agentThinking(label: "Updating schedule…"))
        }

        return items
    }
}
