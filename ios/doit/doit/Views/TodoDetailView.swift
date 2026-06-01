import AuthenticationServices
import PhotosUI
import PostgREST
import Supabase
import SwiftUI

struct TodoDetailView: View {
    /// Hard cap on attached images per task; matches the New Task sheet.
    private static let maxAttachments = 5

    let todo: Todo

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var current: Todo
    @State private var steps: [TodoStep] = []
    /// Full interaction history for this todo (open + closed). Stored as
    /// an array so the chat keeps every Q&A turn visible like a real
    /// chat app; `openInteraction` derives the currently-actionable one.
    @State private var interactions: [TodoInteraction] = []
    @State private var artifacts: [TodoArtifact] = []
    @State private var submittingOptionID: String?
    @State private var error: String?
    @State private var oauthSession: ASWebAuthenticationSession?
    @State private var attachments: [TodoAttachment] = []
    @State private var attachmentURLs: [UUID: URL] = [:]
    @State private var messages: [TodoMessage] = []
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var preview: AttachmentPreview?
    @State private var uploading = false
    @State private var sending = false

    /// Split between the task header and chat thread. The thread gets the
    /// majority of the screen by default; the user can drag, mini, or full
    /// either side via the split's drag pill.
    @State private var splitDetent: SplitDetent = .fraction(0.3)

    /// Detent the user was sitting on when they tapped the composer. We
    /// auto-snap to `.bottomFull` while the chat field is focused so the
    /// composer has the whole screen to work with above the keyboard,
    /// and roll back to whatever they had before once they dismiss.
    @State private var detentBeforeFocus: SplitDetent?

    init(todo: Todo) {
        self.todo = todo
        self._current = State(initialValue: todo)
    }

    var body: some View {
        VerticalSplit(
            detent: $splitDetent,
            topTitle: current.title.isEmpty ? "Task" : current.title,
            bottomTitle: "Chat",
            topView: {
                TaskHeaderView(
                    todo: current,
                    artifacts: artifacts,
                    agentStatus: openInteractionStatus,
                    onBack: { dismiss() },
                    onDelete: deleteTask
                )
            },
            bottomView: {
                TodoChatThread(
                    items: conversationItems,
                    attachmentsByID: attachmentsByID,
                    attachmentURLs: attachmentURLs,
                    submittingOptionID: submittingOptionID,
                    isAgentRunning: current.status.isActive || sending,
                    photoSelections: $photoSelections,
                    canAddMoreAttachments: canAddMoreAttachments,
                    maxNewAttachments: max(1, TodoDetailView.maxAttachments - attachments.count),
                    onTakePhoto: takePhoto,
                    onRemoveAttachment: { attachment in
                        Task { await delete(attachment) }
                    },
                    onPreviewAttachment: { attachment in
                        if let url = attachmentURLs[attachment.id] {
                            preview = AttachmentPreview(url: url)
                        }
                    },
                    onOpenOAuth: { url in startOAuth(url: url) },
                    onRespondInteraction: { envelope, optionID, text in
                        guard case .todo(let interaction) = envelope else { return }
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
                    onConfirmRun: confirmRun,
                    composerReplyHint: openInteractionReplyHint
                )
            }
        )
        .handleTrailingText(formattedTokens(current.total_tokens))
        // The vendor split positions everything (handle pill, mini
        // overlay, wrappers) with absolute offsets and `.ignoresSafeArea()`
        // on the wrappers — but the *root* ZStack still participates in
        // SwiftUI's automatic keyboard avoidance, so showing the keyboard
        // shoves the whole thing (including the `.topMini` pill at the
        // top of `.bottomFull`) up by the keyboard height and clips it
        // off-screen. We do the keyboard lift ourselves inside
        // `TodoChatThread`, so explicitly opt the entire split out of
        // the keyboard region here. Must come *after* the
        // `VerticalSplit`-specific `.handleTrailingText` modifier,
        // since that one only exists on the concrete split type and
        // erasing to `some View` first would hide it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: current.id) {
            // Realtime lives in `TodoRealtimeHub` so `onDisappear` /
            // split-layout churn does not cancel in-flight channel joins.
            // The list calls `endTodoWatch()` when `navigationPath` pops.
            TodoRealtimeHub.beginTodoWatch(
                todoID: current.id,
                handlers: .init(
                    onTodo: { await refreshTodo() },
                    onSteps: { await loadSteps() },
                    onInteractions: { await loadInteractions() },
                    onArtifacts: { await loadArtifacts() },
                    onMessages: { await loadMessages() }
                )
            )
            // Refetch the row on every appearance so columns that mutate
            // mid-run (status, total_tokens, error_message) are fresh —
            // the list view's cached `Todo` can lag, especially after the
            // user navigates back here from the home feed once a run has
            // already incremented tokens.
            await refreshTodo()
            await loadSteps()
            await loadInteractions()
            await loadAttachments()
            await loadArtifacts()
            await loadMessages()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("[detail] scenePhase \(oldPhase)→\(newPhase) todo=\(current.id)")
            guard newPhase == .active else { return }
            Task {
                await refreshTodo()
                await loadSteps()
                await loadInteractions()
                await loadArtifacts()
                await loadMessages()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoRemoteUpdate)) { note in
            guard TodoRemoteUpdate.todoID(from: note) == current.id else { return }
            print("[detail] push refresh todo=\(current.id)")
            Task {
                await refreshTodo()
                await loadSteps()
                await loadInteractions()
                await loadArtifacts()
                await loadMessages()
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onPicked: { image in
                    showCamera = false
                    Task { await uploadCapturedImage(image) }
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $preview) { item in
            AttachmentPreviewScreen(url: item.url) { preview = nil }
        }
        .onChange(of: photoSelections) { _, selections in
            guard !selections.isEmpty else { return }
            Task { await uploadPickedImages(selections) }
        }
    }

    // MARK: - Derived chat data

    private var attachmentsByID: [UUID: TodoAttachment] {
        Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
    }

    private var conversationItems: [ConversationItem] {
        ConversationBuilder.build(
            todo: current,
            steps: steps,
            interactions: interactions,
            attachments: attachments,
            messages: messages,
            error: current.error_message ?? error
        )
    }

    private var canAddMoreAttachments: Bool {
        attachments.count < TodoDetailView.maxAttachments
    }

    /// Latest `.open` interaction (if any) — the one the user is
    /// actively answering. Older closed turns live in `interactions`
    /// alongside it and render as static history bubbles.
    private var openInteraction: TodoInteraction? {
        interactions.last(where: { $0.status == .open })
    }

    /// Summary blurb from the agent's currently-open interaction, shown
    /// in the task header as a "what I'm waiting on" status. `nil`
    /// while there's nothing open so the header doesn't grow a
    /// placeholder slot.
    private var openInteractionStatus: String? {
        guard let summary = openInteraction?.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty
        else { return nil }
        return summary
    }

    /// Placeholder the chat composer should display when the agent
    /// has an open interaction expecting a typed reply. We fall back
    /// to a generic hint so the user always knows the composer is the
    /// way to reply.
    private var openInteractionReplyHint: String? {
        guard let open = openInteraction, open.allowsFreeform else { return nil }
        if let hint = open.freeformPlaceholder?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint
        }
        return "Reply to Hermes"
    }

    /// Compact token count rendered in the drag pill. Hides while the todo
    /// has never run (`nil` or 0) so users don't see "0 tok" on fresh
    /// items. Uses the system locale's compact notation for big numbers,
    /// e.g. `12K tok`, `1.2M tok`.
    private func formattedTokens(_ value: Int64?) -> String? {
        guard let v = value, v > 0 else { return nil }
        if v < 1_000 { return "\(v) tok" }
        let formatted = v.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
        return "\(formatted) tok"
    }

    // MARK: - Actions

    private func takePhoto() {
        #if targetEnvironment(simulator)
        self.error = "Camera isn't available on the simulator."
        #else
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            self.error = "Camera isn't available on this device."
        }
        #endif
    }

    /// Permanent removal of the todo (and its cascaded children). Pops back
    /// to the list immediately so the navigation animation runs in parallel
    /// with the network round-trip — the row is already gone client-side
    /// via realtime by the time the list view re-renders.
    private func deleteTask() {
        let id = current.id
        dismiss()
        Task {
            try? await TodosAPI.delete(id)
        }
    }

    private func respond(
        interaction: TodoInteraction,
        optionID: String?,
        text: String?
    ) async {
        submittingOptionID = optionID ?? "__freeform"
        defer { submittingOptionID = nil }
        let phase: InteractionPhase = interaction.isPreparationPhase ? .prepare : .execute
        do {
            try await TodosAPI.respond(
                to: interaction.id,
                todoID: current.id,
                optionID: optionID,
                text: text,
                phase: phase
            )
            // Optimistic: flip the local row to `.responded` with the
            // submitted answer so the chat keeps showing the question
            // *and* the user's reply, instead of the card vanishing.
            // Realtime will reconcile with the persisted row shortly.
            applyOptimisticResponse(
                interactionID: interaction.id,
                optionID: optionID,
                text: text
            )
            if optionID?.lowercased() == "cancel" {
                current.status = .cancelled
            } else {
                // Keep the status in an "active" bucket so the header
                // reads "Doing" while the runner re-claims; without
                // this it briefly flashes through `needs_input` again
                // before realtime catches up.
                current.status = phase.nextStatus
            }
        } catch {
            print("[interaction] respond failed: \(error)")
            self.error = "Couldn't send your response: \(error.localizedDescription)"
        }
    }

    /// Mutate the local `interactions` row in place so the chat
    /// transcript reflects the new `.responded` state immediately. We
    /// build a synthetic JSON payload that mirrors what the server
    /// will end up storing (`{option_id, text}`) so the same helpers
    /// (`respondedBubbleText`, `respondedOptionID`, …) work whether
    /// we're displaying optimistic local state or a freshly-loaded
    /// realtime row.
    private func applyOptimisticResponse(
        interactionID: UUID,
        optionID: String?,
        text: String?
    ) {
        guard let idx = interactions.firstIndex(where: { $0.id == interactionID }) else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        var responseObj: [String: JSONValue] = [:]
        if let id = optionID, !id.isEmpty {
            responseObj["option_id"] = .string(id)
        }
        if let body = trimmed, !body.isEmpty {
            responseObj["text"] = .string(body)
        }
        let now = Date()
        interactions[idx].status = (optionID?.lowercased() == "cancel") ? .cancelled : .responded
        interactions[idx].response = responseObj.isEmpty ? nil : .object(responseObj)
        interactions[idx].responded_at = now
    }

    /// Free-form chat send from the composer. If there's an open
    /// interaction card we route the typed text as the freeform answer to
    /// that card (so a single round-trip both closes the card and resumes
    /// the agent). Otherwise we insert a `todo_messages` row, which the
    /// runner picks up on its next claim. The optimistic local append
    /// makes the bubble appear instantly; realtime will reconcile the row
    /// id once the server returns.
    private func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }

        if let open = openInteraction {
            await respond(interaction: open, optionID: nil, text: trimmed)
            return
        }

        // Optimistic local bubble keyed by a temporary UUID so the chat
        // doesn't feel laggy while the insert + status flip resolves.
        let optimistic = TodoMessage(
            id: UUID(),
            todo_id: current.id,
            user_id: current.user_id,
            body: trimmed,
            consumed_at: nil,
            created_at: Date()
        )
        messages.append(optimistic)
        let priorStatus = current.status
        current.status = .requested

        do {
            let saved = try await TodosAPI.sendMessage(
                todoID: current.id,
                userID: current.user_id,
                body: trimmed
            )
            // Swap the optimistic row for the real one so realtime
            // refreshes don't append a second copy on top of ours.
            if let idx = messages.firstIndex(where: { $0.id == optimistic.id }) {
                messages[idx] = saved
            } else {
                messages.append(saved)
            }
        } catch {
            print("[chat] send failed: \(error)")
            messages.removeAll { $0.id == optimistic.id }
            current.status = priorStatus
            self.error = "Couldn't send your message: \(error.localizedDescription)"
        }
    }

    /// React to the composer field gaining / losing focus. On focus we
    /// record whatever detent the user had set and force `.bottomFull`
    /// so the chat panel claims the full screen above the keyboard. On
    /// blur we restore the saved detent — but only if the user hasn't
    /// dragged the split themselves in the meantime (in which case the
    /// current value won't be `.bottomFull` anymore and we trust the
    /// manual change). The animation here matches the split's own.
    private func handleComposerFocusChange(_ isFocused: Bool) {
        if isFocused {
            if detentBeforeFocus == nil {
                detentBeforeFocus = splitDetent
            }
            withAnimation(.smooth(duration: 0.4)) {
                splitDetent = .bottomFull
            }
        } else {
            guard let prior = detentBeforeFocus else { return }
            detentBeforeFocus = nil
            if splitDetent == .bottomFull {
                withAnimation(.smooth(duration: 0.4)) {
                    splitDetent = prior
                }
            }
        }
    }

    /// Inline "Do it" confirmation from the chat thread's
    /// `.agentReadyToRun` bubble. Mirrors the list-view's pillbutton:
    /// flip the row to `.requested` optimistically (so the chat shows
    /// "Doing" instantly) and let realtime reconcile.
    private func confirmRun() {
        let prior = current.status
        current.status = .requested
        Task {
            do {
                try await TodosAPI.setStatus(current.id, .requested)
            } catch {
                print("[detail] confirmRun failed: \(error)")
                current.status = prior
                self.error = "Couldn't start the task: \(error.localizedDescription)"
            }
        }
    }

    private func startOAuth(url: URL) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { _, _ in
            // The user finishes in the browser; Composio holds the tokens.
            // They can re-tap "Do it" to resume.
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = PresentationContextProvider.shared
        oauthSession = session
        session.start()
    }

    // MARK: - Loading + realtime

    private func loadSteps() async {
        let prevCount = steps.count
        let prevLastID = steps.last?.id
        do {
            steps = try await TodosAPI.steps(for: current.id)
            let lastKind = steps.last?.kind.rawValue ?? "-"
            let lastID = steps.last?.id
            let added = steps.count - prevCount
            let changed = added != 0 || lastID != prevLastID
            print("[realtime][steps] loaded count=\(steps.count) (Δ=\(added)) lastKind=\(lastKind) changed=\(changed) todo=\(current.id)")
            if steps.contains(where: \.containsInteractionMarker) {
                await loadInteractionWithRetry()
            }
        } catch {
            print("[realtime][steps] load failed todo=\(current.id): \(error)")
            self.error = "Couldn't load steps: \(error.localizedDescription)"
        }
    }

    private func loadInteractions() async {
        let prevCount = interactions.count
        let prevOpenID = openInteraction?.id
        do {
            let fresh = try await TodosAPI.interactions(for: current.id)
            // Preserve optimistic local mutations: if we already flipped
            // a row to `.responded` and the server hasn't caught up yet,
            // keep our local copy until realtime confirms.
            let merged: [TodoInteraction] = fresh.map { remote in
                if let local = interactions.first(where: { $0.id == remote.id }),
                   remote.status == .open,
                   local.status != .open {
                    return local
                }
                return remote
            }
            interactions = merged
            let newOpenID = openInteraction?.id
            print("[interaction] loaded count=\(interactions.count) (Δ=\(interactions.count - prevCount)) open=\(newOpenID?.uuidString ?? "nil") prevOpen=\(prevOpenID?.uuidString ?? "nil") todo=\(current.id)")
        } catch {
            print("[interaction] load failed todo=\(current.id): \(error)")
        }
    }

    private func refreshTodo() async {
        let prevStatus = current.status
        let prevTokens = current.total_tokens ?? 0
        do {
            let rows: [Todo] = try await Supa.client
                .from("todos")
                .select()
                .eq("id", value: current.id)
                .limit(1)
                .execute()
                .value
            if let first = rows.first {
                self.current = first
                let newTokens = first.total_tokens ?? 0
                let changed = (prevStatus != first.status) || (prevTokens != newTokens)
                print("[realtime][todo] refreshed id=\(first.id) status=\(prevStatus)→\(first.status) tok=\(prevTokens)→\(newTokens) changed=\(changed)")
                if first.status == .needs_input {
                    await loadInteractionWithRetry()
                }
            } else {
                print("[realtime][todo] refresh returned no rows id=\(current.id)")
            }
        } catch {
            print("[realtime][todo] refresh failed id=\(current.id): \(error)")
        }
    }

    private func loadInteractionWithRetry() async {
        await loadInteractions()
        if openInteraction == nil {
            // The interaction row sometimes lags a beat behind the
            // status flip on Postgres' commit ordering; a single
            // half-second retry covers that race without spamming.
            try? await Task.sleep(for: .milliseconds(500))
            await loadInteractions()
        }
    }

    // MARK: - Artifacts

    private func loadArtifacts() async {
        do {
            let rows = try await TodosAPI.artifacts(for: current.id)
            // Drop empty/malformed rows defensively so the header view
            // never tries to render a card with no content.
            artifacts = rows.filter(\.hasContent)
            print("[artifacts] loaded count=\(artifacts.count) todo=\(current.id)")
        } catch {
            print("[artifacts] load failed todo=\(current.id): \(error)")
        }
    }

    // MARK: - Messages

    private func loadMessages() async {
        do {
            let fresh = try await TodosAPI.messages(for: current.id)
            // Preserve any optimistic locals we inserted but the server
            // hasn't echoed back yet (shouldn't happen often since the
            // insert API returns the persisted row, but guard against
            // races on the scenePhase refresh path).
            let knownIDs = Set(fresh.map(\.id))
            let pending = messages.filter { !knownIDs.contains($0.id) && $0.consumed_at == nil }
            messages = fresh + pending
            print("[chat] messages loaded count=\(messages.count) todo=\(current.id)")
        } catch {
            print("[chat] messages load failed todo=\(current.id): \(error)")
        }
    }

    // MARK: - Attachments

    private func loadAttachments() async {
        do {
            attachments = try await AttachmentsAPI.list(forTodoID: current.id)
            await refreshAttachmentURLs()
        } catch {
            print("[attachments] load failed todo=\(current.id): \(error)")
        }
    }

    private func refreshAttachmentURLs() async {
        var resolved: [UUID: URL] = [:]
        for attachment in attachments {
            do {
                let url = try await AttachmentsAPI.signedURL(for: attachment)
                resolved[attachment.id] = url
            } catch {
                print("[attachments] sign failed id=\(attachment.id): \(error)")
            }
        }
        attachmentURLs = resolved
    }

    private func uploadCapturedImage(_ image: UIImage) async {
        await uploadImages([image])
    }

    private func uploadPickedImages(_ selections: [PhotosPickerItem]) async {
        let remainingSlots = TodoDetailView.maxAttachments - attachments.count
        let slice = Array(selections.prefix(max(0, remainingSlots)))
        var images: [UIImage] = []
        for item in slice {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            } catch {
                self.error = "Couldn't load that photo."
            }
        }
        photoSelections = []
        if !images.isEmpty {
            await uploadImages(images)
        }
    }

    private func uploadImages(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        var failures = 0
        for image in images {
            do {
                let attachment = try await AttachmentsAPI.upload(
                    image: image,
                    todoID: current.id,
                    userID: current.user_id
                )
                attachments.append(attachment)
                if let url = try? await AttachmentsAPI.signedURL(for: attachment) {
                    attachmentURLs[attachment.id] = url
                }
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            self.error = failures == 1
                ? "1 image failed to upload."
                : "\(failures) images failed to upload."
        }
    }

    private func delete(_ attachment: TodoAttachment) async {
        do {
            try await AttachmentsAPI.delete(attachment)
            attachments.removeAll { $0.id == attachment.id }
            attachmentURLs.removeValue(forKey: attachment.id)
        } catch {
            self.error = "Couldn't delete that image: \(error.localizedDescription)"
        }
    }
}

private struct AttachmentPreview: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AttachmentPreviewScreen: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                case .failure:
                    Text("Couldn't load this image.")
                        .foregroundStyle(.white)
                default:
                    ProgressView().tint(.white)
                }
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel("Close preview")
        }
    }
}

/// ASWebAuthenticationSession needs a window to anchor on.
@MainActor
final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}
