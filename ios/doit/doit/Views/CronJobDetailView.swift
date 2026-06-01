import SwiftUI

struct CronJobDetailView: View {
    let job: CronJob

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var current: CronJob
    @State private var interactions: [CronJobInteraction] = []
    @State private var messages: [CronJobMessage] = []
    @State private var submittingOptionID: String?
    @State private var error: String?
    @State private var sending = false
    @State private var splitDetent: SplitDetent = .fraction(0.3)
    @State private var detentBeforeFocus: SplitDetent?

    init(job: CronJob) {
        self.job = job
        self._current = State(initialValue: job)
    }

    var body: some View {
        VerticalSplit(
            detent: $splitDetent,
            topTitle: current.name,
            bottomTitle: "Chat",
            topView: {
                CronJobHeaderView(
                    job: current,
                    agentStatus: openInteractionStatus,
                    onBack: { dismiss() },
                    onDelete: deleteJob
                )
            },
            bottomView: {
                TodoChatThread(
                    items: conversationItems,
                    attachmentsByID: [:],
                    attachmentURLs: [:],
                    submittingOptionID: submittingOptionID,
                    isAgentRunning: current.state.isActive || sending,
                    photoSelections: .constant([]),
                    canAddMoreAttachments: false,
                    maxNewAttachments: 1,
                    onTakePhoto: {},
                    onRemoveAttachment: { _ in },
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
        .task(id: current.id) {
            TodoRealtimeHub.beginCronJobWatch(
                jobID: current.id,
                handlers: .init(
                    onJob: { await refreshJob() },
                    onInteractions: { await loadInteractions() },
                    onMessages: { await loadMessages() }
                )
            )
            await refreshJob()
            await loadInteractions()
            await loadMessages()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await refreshJob()
                await loadInteractions()
                await loadMessages()
            }
        }
    }

    private var conversationItems: [ConversationItem] {
        CronConversationBuilder.build(
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
        let id = current.id
        dismiss()
        Task { try? await CronJobsAPI.delete(id) }
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
                jobID: current.id,
                optionID: optionID,
                text: text
            )
            applyOptimisticResponse(
                interactionID: interaction.id,
                optionID: optionID,
                text: text
            )
            if optionID?.lowercased() == "cancel" {
                current.state = .paused
                current.enabled = false
            } else {
                current.state = .configuring
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
            cron_job_id: current.id,
            user_id: current.user_id,
            body: trimmed,
            consumed_at: nil,
            created_at: Date()
        )
        messages.append(optimistic)
        let priorState = current.state
        current.state = .configuring

        do {
            let saved = try await CronJobsAPI.sendMessage(
                jobID: current.id,
                userID: current.user_id,
                body: trimmed
            )
            if let idx = messages.firstIndex(where: { $0.id == optimistic.id }) {
                messages[idx] = saved
            } else {
                messages.append(saved)
            }
        } catch {
            messages.removeAll { $0.id == optimistic.id }
            current.state = priorState
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

    private func refreshJob() async {
        do {
            current = try await CronJobsAPI.fetch(current.id)
        } catch {
            print("[cron] refresh failed: \(error)")
        }
    }

    private func loadInteractions() async {
        do {
            interactions = try await CronJobsAPI.interactions(for: current.id)
        } catch {
            print("[cron] interactions load failed: \(error)")
        }
    }

    private func loadMessages() async {
        do {
            messages = try await CronJobsAPI.messages(for: current.id)
        } catch {
            print("[cron] messages load failed: \(error)")
        }
    }
}
