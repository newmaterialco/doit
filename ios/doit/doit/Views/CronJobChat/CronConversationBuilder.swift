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
        var latestUserTurn: (id: String, ts: Date)?

        func noteUserTurn(id: String, ts: Date) {
            if latestUserTurn == nil || ts > latestUserTurn!.ts {
                latestUserTurn = (id, ts)
            }
        }

        for message in messages {
            dated.append(Dated(
                item: .userMessage(id: message.id, text: message.body, ts: message.created_at),
                ts: message.created_at,
                tiebreaker: 0
            ))
            if message.consumed_at != nil {
                noteUserTurn(id: message.id.uuidString, ts: message.created_at)
            }
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
                noteUserTurn(id: interaction.id.uuidString, ts: replyTs)
            }
        }
        if let confirmation = reconfigurationConfirmation(for: job, latestUserTurn: latestUserTurn) {
            dated.append(Dated(
                item: confirmation.item,
                ts: confirmation.ts,
                tiebreaker: 3
            ))
        }
        dated.sort { lhs, rhs in
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            return lhs.tiebreaker < rhs.tiebreaker
        }
        items.append(contentsOf: dated.map(\.item))

        let openInteraction = interactions.last(where: { $0.status == .open })
        if job.state == .configuring && openInteraction == nil {
            items.append(.agentThinking(label: "Updating schedule…"))
        }

        return items
    }

    private static func reconfigurationConfirmation(
        for job: CronJob,
        latestUserTurn: (id: String, ts: Date)?
    ) -> (item: ConversationItem, ts: Date)? {
        guard job.state == .scheduled,
              let latestUserTurn,
              job.updated_at >= latestUserTurn.ts else {
            return nil
        }
        let schedule = job.schedulePillText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = schedule.isEmpty
            ? "Updated. This scheduled task is ready to run."
            : "Updated. This scheduled task will now run \(schedule)."
        let id = [
            job.id.uuidString,
            latestUserTurn.id,
            job.updated_at.ISO8601Format()
        ].joined(separator: "-")
        return (
            item: .agentConfirmation(id: id, text: text, ts: job.updated_at),
            ts: job.updated_at
        )
    }
}
