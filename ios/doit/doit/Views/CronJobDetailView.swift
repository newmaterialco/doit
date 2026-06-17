import SwiftUI

struct CronJobDetailView: View {
    /// We open the cron detail view by id (not by passing a `CronJob`
    /// snapshot) so the header always reflects the latest row from
    /// `TodoStore`. See `docs/task-realtime.md`.
    let jobID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(TodoStore.self) private var store

    /// Chat-only state owned by the detail view. The cron job row lives in
    /// the store; full interaction history is per-detail because the user
    /// feed doesn't pre-load it.
    @State private var interactions: [CronJobInteraction] = []
    @State private var messages: [CronJobMessage] = []
    @State private var submittingOptionID: String?
    @State private var error: String?
    @State private var sending = false
    @State private var splitDetent: SplitDetent = .fraction(0.3)
    @State private var detentBeforeFocus: SplitDetent?

    init(jobID: UUID) {
        self.jobID = jobID
    }

    private var current: CronJob? {
        store.cronJob(id: jobID)
    }

    var body: some View {
        VerticalSplit(
            detent: $splitDetent,
            topTitle: current?.name ?? "Scheduled",
            bottomTitle: "Chat",
            topView: {
                Group {
                    if let current {
                        CronJobHeaderView(
                            job: current,
                            agentStatus: openInteractionStatus,
                            onBack: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            },
                            onDelete: deleteJob
                        )
                    } else {
                        Color.clear.onAppear { dismiss() }
                    }
                }
            },
            bottomView: {
                TodoChatThread(
                    items: conversationItems,
                    attachmentsByID: [:],
                    attachmentURLs: [:],
                    submittingOptionID: submittingOptionID,
                    photoSelections: .constant([]),
                    canAddMoreAttachments: false,
                    maxNewAttachments: 1,
                    onTakePhoto: {},
                    onPreviewAttachment: { _ in },
                    onOpenOAuth: { _ in },
                    onRespondInteraction: { envelope, optionID, text in
                        guard case .cron(let interaction) = envelope else { return }
                        Task {
                            await respond(
                                interaction: interaction,
                                optionID: optionID,
                                text: text
                            )
                        }
                    },
                    onSend: { text in
                        Task { await send(text) }
                    },
                    onFocusChange: handleComposerFocusChange,
                    onConfirmRun: {},
                    composerReplyHint: openInteractionReplyHint
                )
            }
        )
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task(id: jobID) {
            // The cron job row lives in the user-feed store. We only need
            // a per-job watch for chat-only tables (`cron_job_messages`,
            // `cron_job_interactions`).
            TodoRealtimeHub.beginCronJobWatch(
                jobID: jobID,
                handlers: .init(
                    onMessages: { await loadMessages() },
                    onInteractions: { await loadInteractions() }
                )
            )
            await store.refreshCronJob(id: jobID)
            await loadInteractions()
            await loadMessages()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await store.refreshCronJob(id: jobID)
                await loadInteractions()
                await loadMessages()
            }
        }
    }

    private var conversationItems: [ConversationItem] {
        guard let current else { return [] }
        return CronConversationBuilder.build(
            job: current,
            interactions: interactions,
            messages: messages
        )
    }

    private var openInteraction: CronJobInteraction? {
        interactions.last(where: { $0.status == .open })
    }

    private var openInteractionStatus: String? {
        if let summary = openInteraction?.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        return openInteraction?.prompt
    }

    private var openInteractionReplyHint: String? {
        guard let open = openInteraction, open.allowsFreeform else { return nil }
        return open.freeformPlaceholder ?? "Describe how you'd like this to run"
    }

    private func deleteJob() {
        let id = jobID
        dismiss()
        Task { await store.deleteCronJob(id) }
    }

    private func respond(
        interaction: CronJobInteraction,
        optionID: String?,
        text: String?
    ) async {
        submittingOptionID = optionID ?? "__freeform"
        defer { submittingOptionID = nil }
        do {
            try await CronJobsAPI.respond(
                to: interaction.id,
                jobID: jobID,
                optionID: optionID,
                text: text
            )
            applyOptimisticResponse(
                interactionID: interaction.id,
                optionID: optionID,
                text: text
            )
            // Reflect the user's reply in the store so the list card
            // updates without waiting for the realtime echo.
            if optionID?.lowercased() == "cancel" {
                await store.refreshCronJob(id: jobID)
            } else {
                await store.refreshCronJob(id: jobID)
            }
        } catch {
            self.error = "Couldn't send your response: \(error.localizedDescription)"
        }
    }

    private func applyOptimisticResponse(
        interactionID: UUID,
        optionID: String?,
        text: String?
    ) {
        guard let idx = interactions.firstIndex(where: { $0.id == interactionID }) else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        var responseObj: [String: JSONValue] = [:]
        if let id = optionID, !id.isEmpty { responseObj["option_id"] = .string(id) }
        if let body = trimmed, !body.isEmpty { responseObj["text"] = .string(body) }
        interactions[idx].status = (optionID?.lowercased() == "cancel") ? .cancelled : .responded
        interactions[idx].response = responseObj.isEmpty ? nil : .object(responseObj)
        interactions[idx].responded_at = Date()
    }

    private func send(_ text: String) async {
        guard let current else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }

        if let open = openInteraction {
            await respond(interaction: open, optionID: nil, text: trimmed)
            return
        }

        let optimistic = CronJobMessage(
            id: UUID(),
            cron_job_id: jobID,
            user_id: current.user_id,
            body: trimmed,
            consumed_at: nil,
            created_at: Date()
        )
        messages.append(optimistic)

        do {
            let saved = try await CronJobsAPI.sendMessage(
                jobID: jobID,
                userID: current.user_id,
                body: trimmed
            )
            if let idx = messages.firstIndex(where: { $0.id == optimistic.id }) {
                messages[idx] = saved
            } else if let idx = messages.firstIndex(where: { $0.id == saved.id }) {
                messages[idx] = saved
            } else if let idx = messages.firstIndex(where: { message in
                message.body == saved.body
                    && abs(message.created_at.timeIntervalSince(optimistic.created_at)) < 10
            }) {
                messages[idx] = saved
            } else {
                messages.append(saved)
            }
            // `sendMessage` re-queues the job; refresh so the list card
            // shows "Setting up…" right away.
            await store.refreshCronJob(id: jobID)
        } catch {
            messages.removeAll { $0.id == optimistic.id }
            self.error = "Couldn't send your message: \(error.localizedDescription)"
        }
    }

    private func handleComposerFocusChange(_ isFocused: Bool) {
        if isFocused {
            if detentBeforeFocus == nil { detentBeforeFocus = splitDetent }
            withAnimation(.smooth(duration: 0.4)) { splitDetent = .bottomFull }
        } else {
            guard let prior = detentBeforeFocus else { return }
            detentBeforeFocus = nil
            if splitDetent == .bottomFull {
                withAnimation(.smooth(duration: 0.4)) { splitDetent = prior }
            }
        }
    }

    private func loadInteractions() async {
        do {
            interactions = try await CronJobsAPI.interactions(for: jobID)
        } catch {
            print("[cron] interactions load failed: \(error)")
        }
    }

    private func loadMessages() async {
        do {
            messages = mergedMessages(with: try await CronJobsAPI.messages(for: jobID))
        } catch {
            print("[cron] messages load failed: \(error)")
        }
    }

    private func mergedMessages(with fetched: [CronJobMessage]) -> [CronJobMessage] {
        var mergedByID: [UUID: CronJobMessage] = [:]
        for message in messages + fetched {
            mergedByID[message.id] = message
        }
        return mergedByID.values.sorted { lhs, rhs in
            if lhs.created_at != rhs.created_at { return lhs.created_at < rhs.created_at }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
