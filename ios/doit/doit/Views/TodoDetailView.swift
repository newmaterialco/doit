import AuthenticationServices
import PhotosUI
import SwiftUI

struct TodoDetailView: View {
    /// Hard cap on attached images per task; matches the New Task sheet.
    private static let maxAttachments = 5

    /// We open the detail view by id (not by passing a `Todo` snapshot) so
    /// the header always reflects the latest row from `TodoStore`. If a
    /// realtime update lands while the user is here, the header redraws
    /// automatically without a manual refetch. See `docs/task-realtime.md`.
    let todoID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(TodoStore.self) private var store
    @Environment(ConnectivityMonitor.self) private var connectivity

    /// Chat-only state owned by the detail view. Task row, artifacts, and
    /// interaction history all come from the store.
    @State private var steps: [TodoStep] = []
    @State private var submittingOptionID: String?
    @State private var error: String?
    @State private var oauthSession: ASWebAuthenticationSession?
    @State private var connectingToolkitSlug: String?
    @State private var attachments: [TodoAttachment] = []
    @State private var attachmentURLs: [UUID: URL] = [:]
    @State private var messages: [TodoMessage] = []
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var preview: AttachmentPreview?
    @State private var uploading = false
    @State private var sending = false

    /// Notch 1 (~17% task) — auto-open when the agent is waiting on a reply.
    private static let chatAutoExpandedTopFraction = 1.0 / 6.0
    /// Notch 2 (~33% task) — manual expand when the user taps the truncated
    /// task-title pill at the top (`.bottomFull`).
    private static let chatTappedExpandedTopFraction = 2.0 / 6.0

    private static var chatExpandedDetent: SplitDetent {
        .fraction(chatAutoExpandedTopFraction)
    }

    private static var chatTappedDetent: SplitDetent {
        .fraction(chatTappedExpandedTopFraction)
    }

    /// Split between the task header and chat thread. Usually opens with chat
    /// collapsed (`.topFull`); when the agent has an open follow-up we start at
    /// `chatExpandedDetent` so the question and composer are visible.
    @State private var splitDetent: SplitDetent = .topFull
    /// Set while the user confirms delete so we don't call `dismiss()`
    /// twice when the store removes the row before the pop finishes.
    @State private var isDeletingTask = false

    /// Detent the user was sitting on when they tapped the composer. We
    /// auto-snap to `.bottomFull` while the chat field is focused so the
    /// composer has the whole screen to work with above the keyboard,
    /// and roll back to whatever they had before once they dismiss.
    @State private var detentBeforeFocus: SplitDetent?

    /// Pending artifact-reference insertion routed from the `@` picker
    /// down to the `MentionTextView`. Each selection generates a new
    /// `ArtifactInsertionRequest` with a unique id so the composer's
    /// coordinator can dedupe re-renders against already-consumed
    /// requests.
    @State private var pendingArtifactInsertion: ArtifactInsertionRequest?

    init(todoID: UUID) {
        self.todoID = todoID
    }

    /// Current task row from the store. Until the first refresh lands we
    /// fall back to a placeholder so the layout doesn't flicker between
    /// "loading" and "empty" — the header just renders an empty title.
    private var current: Todo? {
        store.todo(id: todoID)
    }

    /// Full interaction history for the chat thread.
    private var interactions: [TodoInteraction] {
        store.interactions(for: todoID)
    }

    /// Latest artifacts (header cards).
    private var artifacts: [TodoArtifact] {
        store.artifacts(for: todoID)
    }

    /// Composer-shaped artifact list. We deduplicate via the same
    /// `groupedForDisplay` rule the header uses so the @ picker shows
    /// the same set the user can see on screen, and we drop kinds the
    /// composer can't represent (audio playback, malformed payloads).
    private var artifactReferences: [ArtifactReference] {
        let grouped = TodoArtifact.groupedForDisplay(artifacts)
        let ordered = grouped.primary + grouped.emailDrafts
        return ordered.compactMap(ArtifactReference.init(artifact:))
    }

    var body: some View {
        VerticalSplit(
            detent: $splitDetent,
            topTitle: topTitle,
            bottomTitle: "Chat",
            topView: { topContent },
            bottomView: { chatContent }
        )
        .collapsedTapDetent(Self.chatExpandedDetent)
        .collapsedTopTapDetent(Self.chatTappedDetent)
        .handleTrailingText(formattedTokens(current?.total_tokens))
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
        .onChange(of: openInteractionAwaitingReplyID) { _, interactionID in
            // Agent posted a follow-up (quick-reply buttons or a freeform
            // question) while we were collapsed — expand chat so it's in view.
            guard interactionID != nil, splitDetent == .topFull else { return }
            withAnimation(.smooth(duration: 0.4)) {
                splitDetent = Self.chatExpandedDetent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: todoID) {
            applyInitialSplitDetent()
            detentBeforeFocus = nil
            // Realtime for the task row, interactions, and artifacts flows
            // through the app-scoped user feed → `TodoStore`. The hub's
            // per-todo watch only covers chat-only tables (`todo_steps`,
            // `todo_messages`) that the user feed doesn't carry. The list
            // calls `endTodoWatch()` when `navigationPath` pops.
            TodoRealtimeHub.beginTodoWatch(
                todoID: todoID,
                handlers: .init(
                    onSteps: { await loadSteps() },
                    onMessages: { await loadMessages() }
                )
            )
            // Tell the store this todo is now in front of the user. The
            // store refreshes the row + artifacts + full interaction
            // history so columns that mutate mid-run (status, total_tokens,
            // error_message) are fresh even if the list snapshot lagged.
            store.beginTracking(todoID: todoID)
            await loadSteps()
            await loadAttachments()
            await loadMessages()
        }
        .onDisappear {
            store.endTracking(todoID: todoID)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("[detail] scenePhase \(oldPhase)→\(newPhase) todo=\(todoID)")
            guard newPhase == .active else { return }
            Task {
                await store.refreshTodoSurface(id: todoID)
                await store.refreshInteractions(for: todoID)
                await loadSteps()
                await loadMessages()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoRemoteUpdate)) { note in
            guard TodoRemoteUpdate.todoID(from: note) == todoID else { return }
            print("[detail] push refresh todo=\(todoID)")
            Task {
                await store.refreshTodoSurface(id: todoID)
                await store.refreshInteractions(for: todoID)
                await loadSteps()
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

    private var topTitle: String {
        guard let title = current?.title, !title.isEmpty else { return "Task" }
        return title
    }

    @ViewBuilder
    private var topContent: some View {
        if let current {
            TaskHeaderView(
                todo: current,
                artifacts: artifacts,
                agentStatus: openInteractionStatus,
                agentActivity: store.agentActivity(for: todoID),
                onBack: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss()
                },
                onDelete: deleteTask,
                onTapActivity: openChat
            )
        } else if !isDeletingTask {
            Color.clear
                .onAppear { dismiss() }
        } else {
            Color.clear
        }
    }

    private var chatAuthToolkitName: String? {
        authToolkitSlug.map { toolkitName(for: $0) }
    }

    private var maxNewAttachmentCount: Int {
        max(1, TodoDetailView.maxAttachments - attachments.count)
    }

    @ViewBuilder
    private var chatContent: some View {
        TodoChatThread(
            items: conversationItems,
            attachmentsByID: attachmentsByID,
            attachmentURLs: attachmentURLs,
            submittingOptionID: submittingOptionID,
            photoSelections: $photoSelections,
            canAddMoreAttachments: canAddMoreAttachments,
            maxNewAttachments: maxNewAttachmentCount,
            onTakePhoto: takePhoto,
            onPreviewAttachment: previewAttachment,
            onOpenOAuth: startOAuth,
            authToolkitSlug: authToolkitSlug,
            authToolkitName: chatAuthToolkitName,
            connectingToolkitSlug: connectingToolkitSlug,
            onConnectToolkit: connectToolkit,
            onRespondInteraction: handleInteractionResponse,
            onSend: handleChatSend,
            onFocusChange: handleComposerFocusChange,
            onConfirmRun: confirmRun,
            composerReplyHint: openInteractionReplyHint,
            availableReferences: artifactReferences,
            pendingArtifactInsertion: $pendingArtifactInsertion
        )
    }

    private func previewAttachment(_ attachment: TodoAttachment) {
        if let url = attachmentURLs[attachment.id] {
            preview = AttachmentPreview(url: url)
        }
    }

    private func handleInteractionResponse(
        _ envelope: ChatInteractionEnvelope,
        optionID: String?,
        text: String?
    ) {
        guard case .todo(let interaction) = envelope else { return }
        Task {
            await respond(interaction: interaction, optionID: optionID, text: text)
        }
    }

    private func handleChatSend(_ text: String) {
        Task { await send(text) }
    }

    // MARK: - Derived chat data

    private var attachmentsByID: [UUID: TodoAttachment] {
        Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
    }

    private var conversationItems: [ConversationItem] {
        guard let current else { return [] }
        return ConversationBuilder.build(
            todo: current,
            steps: steps,
            interactions: interactions,
            attachments: attachments,
            messages: messages,
            error: current.error_message ?? error,
            agentActivity: store.agentActivity(for: todoID)
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

    /// Open follow-up the user still needs to answer — quick-reply buttons
    /// and/or a freeform question in the composer. We consult both the full
    /// interaction history and the list-scoped open snapshot because the
    /// detail view can appear before `refreshInteractions` lands.
    private var interactionAwaitingUserReply: TodoInteraction? {
        for candidate in [openInteraction, store.openInteractions[todoID]] {
            guard let interaction = candidate,
                  interaction.status == .open
            else { continue }
            return interaction
        }
        return nil
    }

    private var openInteractionAwaitingReplyID: UUID? {
        interactionAwaitingUserReply?.id
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
        return "Reply to doit"
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

    private func applyInitialSplitDetent() {
        splitDetent = interactionAwaitingUserReply != nil
            ? Self.chatExpandedDetent
            : .topFull
    }

    private func openChat() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.4)) {
            splitDetent = Self.chatExpandedDetent
        }
    }

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
    /// via the store by the time the list view re-renders.
    private func deleteTask() {
        guard !isDeletingTask else { return }
        isDeletingTask = true
        let id = todoID
        dismiss()
        Task { await store.deleteTodo(id) }
    }

    private func respond(
        interaction: TodoInteraction,
        optionID: String?,
        text: String?
    ) async {
        guard let current else { return }
        submittingOptionID = optionID ?? "__freeform"
        defer { submittingOptionID = nil }
        // Store owns the optimistic mutation + the API call so the chat
        // bubble flips to `.responded` instantly and the list card stays
        // in sync.
        await store.respond(
            to: interaction,
            todo: current,
            optionID: optionID,
            text: text
        )
    }

    /// Free-form chat send from the composer. If there's an open
    /// interaction card we route the typed text as the freeform answer to
    /// that card (so a single round-trip both closes the card and resumes
    /// the agent). Otherwise we insert a `todo_messages` row, which the
    /// runner picks up on its next claim. The optimistic local append
    /// makes the bubble appear instantly; realtime will reconcile the row
    /// id once the server returns.
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
        // Status flip + REST call go through the store so the list card
        // also reads "Doing" instantly. The runner's resume will write
        // the real status back via realtime.
        await store.setStatus(todoID, .requested)

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
            await store.setStatus(todoID, priorStatus)
            if connectivity.reportFailure(error) {
                self.error = nil
            } else {
                self.error = "Couldn't send your message: \(error.localizedDescription)"
            }
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
    /// flip the row to `.requested` via the store so chat AND list show
    /// "Doing" instantly, then let realtime reconcile.
    private func confirmRun() {
        Task { await store.setStatus(todoID, .requested) }
    }

    private var authToolkitSlug: String? {
        guard current?.status == .needs_auth else { return nil }
        let slug = current?.connection_slug?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (slug?.isEmpty == false) ? slug : nil
    }

    private func startOAuth(url: URL) {
        Task {
            await runOAuthAndMaybeResume(url: url, toolkitSlug: authToolkitSlug)
        }
    }

    private func connectToolkit(_ slug: String) {
        Task { await connectToolkitAndResume(slug) }
    }

    private func connectToolkitAndResume(_ slug: String) async {
        let normalizedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSlug.isEmpty else { return }
        connectingToolkitSlug = normalizedSlug
        error = nil
        defer { connectingToolkitSlug = nil }

        do {
            let result = try await IntegrationsAPI.connect(toolkit: normalizedSlug)
            guard let urlString = result.redirect_url,
                  let url = URL(string: urlString) else {
                error = "Couldn't start the \(toolkitName(for: normalizedSlug)) connection."
                return
            }
            await runOAuthAndMaybeResume(
                url: url,
                toolkitSlug: normalizedSlug,
                showConnectionError: true
            )
        } catch {
            if connectivity.reportFailure(error) {
                self.error = nil
            } else {
                self.error = "Couldn't start the \(toolkitName(for: normalizedSlug)) connection: \(error.localizedDescription)"
            }
        }
    }

    private func runOAuthAndMaybeResume(
        url: URL,
        toolkitSlug: String?,
        showConnectionError: Bool = false
    ) async {
        await runOAuthSession(url: url)
        guard let toolkitSlug else { return }

        do {
            let toolkits = try await IntegrationsAPI.list()
            if toolkits.contains(where: { $0.slug == toolkitSlug && $0.connected }) {
                await store.setStatus(todoID, .requested)
                error = nil
            } else if showConnectionError {
                error = "Finish connecting \(toolkitName(for: toolkitSlug)) to continue this task."
            }
        } catch {
            if connectivity.reportFailure(error) {
                self.error = nil
            } else {
                self.error = "Couldn't verify the \(toolkitName(for: toolkitSlug)) connection: \(error.localizedDescription)"
            }
        }
    }

    private func runOAuthSession(url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: nil
            ) { _, _ in
                cont.resume()
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = PresentationContextProvider.shared
            oauthSession = session
            if !session.start() {
                cont.resume()
            }
        }
    }

    private func toolkitName(for slug: String) -> String {
        if let cached = IntegrationsAPI.cachedToolkits?
            .first(where: { $0.slug == slug })?
            .name {
            return cached
        }
        switch slug {
        case "gmail": return "Gmail"
        case "googlecalendar": return "Google Calendar"
        case "googledrive": return "Google Drive"
        case "googledocs": return "Google Docs"
        case "googlesheets": return "Google Sheets"
        case "github": return "GitHub"
        case "linkedin": return "LinkedIn"
        default:
            return slug
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    // MARK: - Loading + realtime
    //
    // Detail-only state. Task row, interactions, and artifacts live in
    // `TodoStore` and are kept fresh by the user-feed realtime path. The
    // detail view only owns chat-only state (`todo_steps`, `todo_messages`,
    // attachments) that the user feed does not carry.

    private func loadSteps() async {
        let prevCount = steps.count
        let prevLastID = steps.last?.id
        do {
            steps = try await TodosAPI.steps(for: todoID)
            let lastKind = steps.last?.kind.rawValue ?? "-"
            let lastID = steps.last?.id
            let added = steps.count - prevCount
            let changed = added != 0 || lastID != prevLastID
            print("[realtime][steps] loaded count=\(steps.count) (Δ=\(added)) lastKind=\(lastKind) changed=\(changed) todo=\(todoID)")
            if steps.contains(where: \.containsInteractionMarker) {
                await refreshInteractionsWithRetry()
            }
            connectivity.reportSuccess()
        } catch {
            print("[realtime][steps] load failed todo=\(todoID): \(error)")
            if connectivity.reportFailure(error) {
                self.error = nil
            } else {
                self.error = "Couldn't load steps: \(error.localizedDescription)"
            }
        }
    }

    /// The interaction row sometimes lags a beat behind the status flip on
    /// Postgres' commit ordering; a single half-second retry through the
    /// store covers that race without spamming.
    private func refreshInteractionsWithRetry() async {
        await store.refreshInteractions(for: todoID)
        if openInteraction == nil {
            try? await Task.sleep(for: .milliseconds(500))
            await store.refreshInteractions(for: todoID)
        }
    }

    // MARK: - Messages

    private func loadMessages() async {
        do {
            let fresh = try await TodosAPI.messages(for: todoID)
            // Preserve any optimistic locals we inserted but the server
            // hasn't echoed back yet (shouldn't happen often since the
            // insert API returns the persisted row, but guard against
            // races on the scenePhase refresh path).
            let knownIDs = Set(fresh.map(\.id))
            let pending = messages.filter { !knownIDs.contains($0.id) && $0.consumed_at == nil }
            messages = fresh + pending
            print("[chat] messages loaded count=\(messages.count) todo=\(todoID)")
        } catch {
            print("[chat] messages load failed todo=\(todoID): \(error)")
        }
    }

    // MARK: - Attachments

    private func loadAttachments() async {
        do {
            attachments = try await AttachmentsAPI.list(forTodoID: todoID)
            await refreshAttachmentURLs()
        } catch {
            print("[attachments] load failed todo=\(todoID): \(error)")
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
        guard let current else { return }
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
