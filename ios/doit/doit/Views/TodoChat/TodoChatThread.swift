import Combine
import PhotosUI
import SwiftUI
import UIKit

/// Shared typography and spacing for the chat transcript.
private enum ChatStyle {
    static let messageFontSize: CGFloat = 17
    static let messageSpacing: CGFloat = 22
    static let optionFontSize: CGFloat = 17
    static let optionVerticalPadding: CGFloat = 14
    static let optionHorizontalPadding: CGFloat = 20
    /// Sent images in the transcript (compact thumbnails).
    static let attachmentImageSize: CGFloat = 110
}

/// Bottom panel of the split-screen detail view: a scrolling conversation
/// of `ConversationItem`s plus a live composer. Free-form sends go through
/// `onSend`; follow-up messages remain available while the agent is active
/// so the user can interrupt or redirect the in-flight Hermes turn.
///
/// Keyboard handling: the parent `VerticalSplit`'s `BottomWrapper` uses
/// `.ignoresSafeArea()`, which suppresses SwiftUI's automatic keyboard
/// avoidance for everything inside the bottom panel. To get the composer
/// to ride above the keyboard we observe `keyboardWillChangeFrameNotification`
/// here and pad the bottom of the chat stack by the visible keyboard
/// height (minus the screen's bottom safe area, which the wrapper has
/// already accounted for). The detent flip to `.bottomFull` is owned by
/// the parent via `onFocusChange` so the top section collapses to its
/// pill when the user starts typing.
struct TodoChatThread: View {
    let items: [ConversationItem]
    let attachmentsByID: [UUID: TodoAttachment]
    let attachmentURLs: [UUID: URL]
    let submittingOptionID: String?
    @Binding var photoSelections: [PhotosPickerItem]
    let canAddMoreAttachments: Bool
    let maxNewAttachments: Int
    let onTakePhoto: () -> Void
    let onPreviewAttachment: (TodoAttachment) -> Void
    let onOpenOAuth: (URL) -> Void
    let authToolkitSlug: String?
    let authToolkitName: String?
    let connectingToolkitSlug: String?
    let onConnectToolkit: (String) -> Void
    let onRespondInteraction: (_ interaction: ChatInteractionEnvelope, _ optionID: String?, _ text: String?) -> Void
    let onSend: (String) -> Void
    let onFocusChange: (Bool) -> Void
    /// Fired by the in-chat "Do it" bubble that appears when the task
    /// is parked at `status == .todo` after the runner finishes its
    /// preparation pass. Routed to `TodosAPI.setStatus(.requested)` so
    /// the runner picks the todo back up.
    let onConfirmRun: () -> Void
    /// When the agent has an open interaction expecting a typed reply,
    /// this is the placeholder hint the composer should show (e.g.
    /// `"Example: Wednesday at 3pm for 30 minutes…"`). The parent
    /// builds it from `interaction.freeformPlaceholder`; `nil` here
    /// means there's nothing pending and the composer uses its
    /// default placeholder.
    let composerReplyHint: String?
    /// Artifact references the composer's `@` picker filters over.
    /// Empty by default so non-todo callers (cron jobs) don't have
    /// to plumb anything through.
    let availableReferences: [ArtifactReference]
    /// Outside-driven insertion ping: the parent sets this when the
    /// user taps an artifact card in the header so the composer
    /// embeds the matching pill at the cursor.
    @Binding var pendingArtifactInsertion: ArtifactInsertionRequest?

    init(
        items: [ConversationItem],
        attachmentsByID: [UUID: TodoAttachment],
        attachmentURLs: [UUID: URL],
        submittingOptionID: String?,
        photoSelections: Binding<[PhotosPickerItem]>,
        canAddMoreAttachments: Bool,
        maxNewAttachments: Int,
        onTakePhoto: @escaping () -> Void,
        onPreviewAttachment: @escaping (TodoAttachment) -> Void,
        onOpenOAuth: @escaping (URL) -> Void,
        authToolkitSlug: String? = nil,
        authToolkitName: String? = nil,
        connectingToolkitSlug: String? = nil,
        onConnectToolkit: @escaping (String) -> Void = { _ in },
        onRespondInteraction: @escaping (_ interaction: ChatInteractionEnvelope, _ optionID: String?, _ text: String?) -> Void,
        onSend: @escaping (String) -> Void,
        onFocusChange: @escaping (Bool) -> Void,
        onConfirmRun: @escaping () -> Void,
        composerReplyHint: String?,
        availableReferences: [ArtifactReference] = [],
        pendingArtifactInsertion: Binding<ArtifactInsertionRequest?> = .constant(nil)
    ) {
        self.items = items
        self.attachmentsByID = attachmentsByID
        self.attachmentURLs = attachmentURLs
        self.submittingOptionID = submittingOptionID
        self._photoSelections = photoSelections
        self.canAddMoreAttachments = canAddMoreAttachments
        self.maxNewAttachments = maxNewAttachments
        self.onTakePhoto = onTakePhoto
        self.onPreviewAttachment = onPreviewAttachment
        self.onOpenOAuth = onOpenOAuth
        self.authToolkitSlug = authToolkitSlug
        self.authToolkitName = authToolkitName
        self.connectingToolkitSlug = connectingToolkitSlug
        self.onConnectToolkit = onConnectToolkit
        self.onRespondInteraction = onRespondInteraction
        self.onSend = onSend
        self.onFocusChange = onFocusChange
        self.onConfirmRun = onConfirmRun
        self.composerReplyHint = composerReplyHint
        self.availableReferences = availableReferences
        self._pendingArtifactInsertion = pendingArtifactInsertion
    }

    /// Current keyboard overlap (in points) over the chat panel. Driven
    /// by `keyboardWillChangeFrameNotification`; we apply it as bottom
    /// padding so the composer rides above the keyboard inside the
    /// vendor split's `.ignoresSafeArea()` bottom wrapper.
    @State private var keyboardLift: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            messageList
                .zIndex(0)
            ChatComposer(
                photoSelections: $photoSelections,
                canAddMoreAttachments: canAddMoreAttachments,
                maxNewAttachments: maxNewAttachments,
                replyHint: composerReplyHint,
                availableReferences: availableReferences,
                pendingInsertion: $pendingArtifactInsertion,
                onTakePhoto: onTakePhoto,
                onSend: onSend,
                onFocusChange: onFocusChange
            )
            .background(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.5), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
            .zIndex(2)
        }
        .padding(.bottom, keyboardLift)
        .animation(.smooth(duration: 0.25), value: keyboardLift)
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        ) { note in
            keyboardLift = visibleKeyboardLift(from: note)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            keyboardLift = 0
        }
    }

    /// Convert a keyboard notification into the amount we need to shift
    /// the chat stack up. The notification's end frame is in screen
    /// coordinates, so we measure how much of it overlaps the screen
    /// and then subtract the bottom safe area that `BottomWrapper`
    /// already left for the home indicator — otherwise we'd double-pad
    /// and leave a ~34pt gap below the composer on Face-ID devices.
    private func visibleKeyboardLift(from note: Notification) -> CGFloat {
        guard
            let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return 0 }
        let screenHeight = UIScreen.main.bounds.height
        let overlap = max(0, screenHeight - endFrame.origin.y)
        guard overlap > 0 else { return 0 }
        let bottomInset = SafeAreaInsetsKey.defaultValue.bottom
        return max(0, overlap - bottomInset)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ChatStyle.messageSpacing) {
                ForEach(items) { item in
                    messageRow(for: item)
                        .id(item.id)
                        .transition(.opacity)
                }
                Color.clear
                    .frame(height: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 76)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // iMessage-style drag-to-dismiss. `.interactively` follows
        // the finger so the keyboard slides away under the user's
        // gesture instead of popping; once focus drops, our
        // `onFocusChange` hook restores the prior split detent.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .onTapGesture {
            // Belt-and-suspenders for non-scroll dismissal — tapping
            // anywhere on the transcript hides the keyboard via the
            // app-wide resignFirstResponder, which trips the same
            // FocusState → detent-restore path as a send.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }

    @ViewBuilder
    private func messageRow(for item: ConversationItem) -> some View {
        switch item {
        case .userRequest(let text, _):
            UserTextBubble(text: text)
        case .userAttachments(let ids):
            let attachments = ids.compactMap { attachmentsByID[$0] }
            UserAttachmentsBubble(
                attachments: attachments,
                urls: attachmentURLs,
                onTap: onPreviewAttachment
            )
        case .userMessage(_, let text, _):
            UserTextBubble(text: text)
        case .agentStep(let step):
            AgentStepMessage(
                step: step,
                authToolkitSlug: authToolkitSlug,
                authToolkitName: authToolkitName,
                isConnectingToolkit: authToolkitSlug != nil
                    && authToolkitSlug == connectingToolkitSlug,
                onOpenOAuth: onOpenOAuth,
                onConnectToolkit: onConnectToolkit
            )
        case .agentThinking(let label):
            AgentThinkingMessage(label: label)
        case .agentInteraction(let interaction):
            AgentInteractionMessage(
                interaction: interaction,
                submittingOptionID: submittingOptionID,
                onRespond: { optionID, text in
                    onRespondInteraction(interaction, optionID, text)
                }
            )
        case .agentError(let text):
            AgentErrorMessage(text: text)
        case .agentReadyToRun(let summary):
            AgentReadyToRunMessage(summary: summary, onConfirm: onConfirmRun)
        }
    }
}

// MARK: - User-side bubbles

private struct UserTextBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            MarkdownMessageText(text: text)
                .multilineTextAlignment(.leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .textSelection(.enabled)
        }
    }
}

private struct MarkdownMessageText: View {
    let text: String
    var foregroundColor: Color = .primary

    var body: some View {
        Text(attributedText)
            .font(.system(size: ChatStyle.messageFontSize, weight: .regular, design: .rounded))
            .foregroundStyle(foregroundColor)
            .tint(.accentColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedText: AttributedString {
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        return parsed.withLinkedPlainURLs(in: text)
    }
}

private extension AttributedString {
    func withLinkedPlainURLs(in source: String) -> AttributedString {
        var attributed = self
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        detector.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let url = match.url,
                  let stringRange = Range(match.range, in: source),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else {
                return
            }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}

/// Right-aligned image strip for a user turn. Sits on the timeline
/// immediately above the text bubble that follows (the builder sorts
/// attachments before messages at the same timestamp). Sent images are
/// read-only — no remove badge.
private struct UserAttachmentsBubble: View {
    let attachments: [TodoAttachment]
    let urls: [UUID: URL]
    let onTap: (TodoAttachment) -> Void

    private var tiles: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                RemoteAttachmentTile(
                    signedURL: urls[attachment.id],
                    size: ChatStyle.attachmentImageSize,
                    onRemove: nil,
                    onTap: { onTap(attachment) }
                )
            }
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 56)
            if attachments.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    tiles
                }
            } else {
                tiles
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Pull the user text bubble up so the image reads as one turn.
        .padding(.bottom, -(ChatStyle.messageSpacing - 8))
    }
}

// MARK: - Agent-side messages (no bubble background)

/// Single-line activity placeholder shown while the agent is actively
/// working but hasn't produced its final reply yet. The `label` is
/// derived in `ConversationBuilder` from the latest in-flight step so it
/// reflects what Hermes is doing right now — e.g. `Working on gmail send
/// email…` or `Reviewing web search result…`. Falls back to `Thinking…`.
///
/// Two animations layered on top of each other:
/// 1. `contentTransition(.opacity)` + an animation bound to `label`
///    crossfades smoothly when the line changes.
/// 2. A self-driven opacity pulse keeps the line subtly alive so the
///    user knows something is still happening between step updates.
///
/// The previous noisy stream of `thought` / `tool_started` / `tool_result`
/// rows is still inserted into `todo_steps` by the runner so other UIs
/// can read them — they just don't render in the chat thread anymore.
private struct AgentThinkingMessage: View {
    let label: String
    @State private var faded = false

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.35), value: label)
            .opacity(faded ? 0.45 : 1.0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                ) {
                    faded = true
                }
            }
            .accessibilityLabel("Hermes is \(label.lowercased())")
    }
}

private struct AgentStepMessage: View {
    let bodyText: String
    let timestamp: Date
    let toolName: String?
    let oauthURL: URL?
    let authToolkitSlug: String?
    let authToolkitName: String?
    let isConnectingToolkit: Bool
    let onOpenOAuth: (URL) -> Void
    let onConnectToolkit: (String) -> Void

    init(
        step: TodoStep,
        authToolkitSlug: String?,
        authToolkitName: String?,
        isConnectingToolkit: Bool,
        onOpenOAuth: @escaping (URL) -> Void,
        onConnectToolkit: @escaping (String) -> Void
    ) {
        self.bodyText = AgentReplyText.normalize(step.text ?? "")
        self.timestamp = step.ts
        self.toolName = step.tool_name
        self.authToolkitSlug = authToolkitSlug
        self.authToolkitName = authToolkitName
        self.isConnectingToolkit = isConnectingToolkit
        if step.kind == .oauth_needed, let urlStr = step.url {
            self.oauthURL = URL(string: urlStr)
        } else {
            self.oauthURL = nil
        }
        self.onOpenOAuth = onOpenOAuth
        self.onConnectToolkit = onConnectToolkit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let toolName, !toolName.isEmpty {
                Text(prettify(toolName))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if !bodyText.isEmpty {
                MarkdownMessageText(text: bodyText)
            }
            if let url = oauthURL {
                oauthButton(url: url)
            }
            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func oauthButton(url: URL) -> some View {
        if let slug = authToolkitSlug, !slug.isEmpty {
            Button {
                onConnectToolkit(slug)
            } label: {
                HStack(spacing: 8) {
                    if isConnectingToolkit {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(slug)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    Text("Connect \(authToolkitName ?? prettify(slug))")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.orange)
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isConnectingToolkit)
        } else {
            Button {
                onOpenOAuth(url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open authorization link")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color.orange)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func prettify(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "mcp ", with: "")
            .capitalized
    }
}

/// Renders an open interaction inline in the transcript. We now only
/// show the question + any structured preview (email draft, JSON
/// payload) + the quick-reply option buttons. The `summary` blurb
/// surfaces in the task header instead so the chat stays focused on
/// the actual Q&A turn. Freeform answers go through the chat composer
/// at the bottom of the screen — `TodoDetailView.send` already routes
/// typed text to the open interaction when one exists, so we don't
/// need a second input field here.
private struct AgentInteractionMessage: View {
    let interaction: ChatInteractionEnvelope
    let submittingOptionID: String?
    let onRespond: (_ optionID: String?, _ text: String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MarkdownMessageText(text: interaction.prompt)

            if let draft = interaction.emailDraft {
                EmailDraftPreview(draft: draft)
            } else if let invite = interaction.calendarInvite {
                CalendarInvitePreview(invite: invite)
            } else if let options = interaction.optionsPayload {
                OptionsPreview(payload: options)
            } else if let content = interaction.content {
                JSONPreview(value: content)
            }

            optionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var optionButtons: some View {
        // Closed interactions are pure history — the synthesised user
        // reply bubble already shows what was picked, so we don't want
        // a second set of (now-stale) buttons sitting under the prompt.
        let opts = interaction.options
        if interaction.status == .open, !opts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(opts) { opt in
                    OptionButton(
                        option: opt,
                        isSubmitting: submittingOptionID == opt.id,
                        disabled: submittingOptionID != nil
                    ) {
                        // Quick-reply taps no longer carry freeform
                        // text; the composer is the single source of
                        // truth for typed answers.
                        onRespond(opt.id, nil)
                    }
                }
            }
        }
    }
}

/// "Ready to do this" bubble shown after the runner has prepared a
/// task and is parked at `status == .todo`. Carries an inline Do it
/// button so the user can confirm without bouncing back to the task
/// list — keeps every confirmation step inside the same chat thread.
private struct AgentReadyToRunMessage: View {
    let summary: String?
    let onConfirm: () -> Void

    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownMessageText(text: summary ?? "Ready when you are.")

            Button {
                guard !submitting else { return }
                submitting = true
                onConfirm()
            } label: {
                HStack(spacing: 8) {
                    if submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Do it")
                        .font(.system(size: ChatStyle.optionFontSize, weight: .semibold, design: .rounded))
                }
                .padding(.vertical, ChatStyle.optionVerticalPadding)
                .padding(.horizontal, ChatStyle.optionHorizontalPadding)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .disabled(submitting)
            .animation(.smooth(duration: 0.2), value: submitting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OptionButton: View {
    let option: InteractionOption
    let isSubmitting: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Text(option.label)
                    .font(.system(size: ChatStyle.optionFontSize, weight: .semibold, design: .rounded))
            }
            .padding(.vertical, ChatStyle.optionVerticalPadding)
            .padding(.horizontal, ChatStyle.optionHorizontalPadding)
            .background(backgroundColor, in: Capsule())
            .foregroundStyle(foregroundColor)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !isSubmitting ? 0.5 : 1)
    }

    private var backgroundColor: Color {
        switch option.style {
        case .destructive: Color.red.opacity(0.12)
        case .secondary: Color.primary.opacity(0.06)
        case .primary, .none: Color.accentColor
        }
    }

    private var foregroundColor: Color {
        switch option.style {
        case .destructive: .red
        case .secondary: Color.primary
        case .primary, .none: .white
        }
    }
}

private struct EmailDraftPreview: View {
    let draft: (subject: String, body: String, to: [String])

    private let cornerRadius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Email draft")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if !draft.to.isEmpty {
                    Text("To: \(draft.to.joined(separator: ", "))")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                Text(draft.subject)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)

                Text(draft.body)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 3)
    }
}

private struct CalendarInviteDraft: Hashable {
    let title: String
    let start: Date?
    let end: Date?
    let timezone: TimeZone?
    let location: String?
    let attendees: [String]
    let url: URL?

    init?(content: JSONValue) {
        guard let obj = content.objectValue else { return nil }
        let rawTitle = obj["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = rawTitle, !title.isEmpty else { return nil }
        let start = obj["start"]?.stringValue.flatMap(Self.parseISO8601)
        let end = obj["end"]?.stringValue.flatMap(Self.parseISO8601)
        let location = obj["location"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attendees = obj["attendees"]?.arrayValue?
            .compactMap { $0.stringValue }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        let timezone = obj["timezone"]?.stringValue.flatMap(TimeZone.init(identifier:))
        let url = obj["url"]?.stringValue.flatMap(URL.init(string:))

        guard start != nil || end != nil || location?.isEmpty == false || !attendees.isEmpty else {
            return nil
        }

        self.title = title
        self.start = start
        self.end = end
        self.timezone = timezone
        self.location = location?.isEmpty == false ? location : nil
        self.attendees = attendees
        self.url = url
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = isoFractional.date(from: trimmed) { return d }
        return isoBasic.date(from: trimmed)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private extension ChatInteractionEnvelope {
    var calendarInvite: CalendarInviteDraft? {
        content.flatMap(CalendarInviteDraft.init(content:))
    }

    var optionsPayload: OptionsPayload? {
        content.flatMap(OptionsPayload.init(json:))
    }
}

private struct CalendarInvitePreview: View {
    let invite: CalendarInviteDraft
    @Environment(\.openURL) private var openURL

    private let cornerRadius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendar invite")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(invite.title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let when = Self.formatRange(invite.start, invite.end, timezone: invite.timezone) {
                    Label(when, systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                }
                if let location = invite.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                }
                if !invite.attendees.isEmpty {
                    Label(invite.attendees.joined(separator: ", "), systemImage: "person.2.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let url = invite.url {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Open in Calendar")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.blue)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 3)
    }

    private static func formatRange(_ start: Date?, _ end: Date?, timezone: TimeZone?) -> String? {
        guard let start else { return nil }
        let startStr = format(start, includeDate: true, timezone: timezone)
        guard let end else { return startStr }

        var calendar = Calendar.current
        if let timezone {
            calendar.timeZone = timezone
        }

        if calendar.isDate(start, inSameDayAs: end) {
            return "\(startStr) - \(format(end, includeDate: false, timezone: timezone))"
        }
        return "\(startStr) - \(format(end, includeDate: true, timezone: timezone))"
    }

    private static func format(_ date: Date, includeDate: Bool, timezone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = includeDate ? .medium : .none
        formatter.timeStyle = .short
        if let timezone {
            formatter.timeZone = timezone
        }
        return formatter.string(from: date)
    }
}

private struct JSONPreview: View {
    let value: JSONValue

    var body: some View {
        Text(prettyPrint(value))
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .textSelection(.enabled)
    }

    private func prettyPrint(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8) else {
            return "(unparseable)"
        }
        return s
    }
}

private struct AgentErrorMessage: View {
    let text: String

    var body: some View {
        MarkdownMessageText(text: text, foregroundColor: .red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Composer

/// Live chat composer. Text + send fire `onSend` with the trimmed,
/// markdown-serialized draft. The composer stays usable while the agent
/// is mid-turn so a follow-up can interrupt or redirect the active run.
///
/// `onFocusChange` is forwarded out so the parent (TodoDetailView) can
/// snap the vertical split to `.bottomFull` while the field is focused
/// and restore the prior detent on blur. Doing this at the parent keeps
/// the composer view itself unaware of the split layout.
private struct ChatComposer: View {
    @Binding var photoSelections: [PhotosPickerItem]
    let canAddMoreAttachments: Bool
    let maxNewAttachments: Int
    /// Open-interaction prompt hint (e.g. "Example: Wednesday at 3pm…").
    /// When present we surface it as the placeholder so the user knows
    /// the composer is the way to answer the agent's pending question.
    let replyHint: String?
    /// Top-section artifacts the user can mention with `@` or by
    /// tapping the cards above. Empty list disables the picker
    /// without removing the composer.
    let availableReferences: [ArtifactReference]
    /// Outside-driven insertion request (artifact card taps in the
    /// header). Internal `@` selections also flow through this same
    /// binding so the underlying `MentionTextView` only has one way
    /// to add a pill.
    @Binding var pendingInsertion: ArtifactInsertionRequest?
    let onTakePhoto: () -> Void
    let onSend: (String) -> Void
    let onFocusChange: (Bool) -> Void

    @State private var draft: MentionDraft = .empty
    @State private var showPhotosPicker = false
    @State private var isFocused: Bool = false
    @State private var mentionQuery: String?
    @State private var voice = VoiceRecorder()
    @State private var isTranscribing = false
    @State private var voiceError: String?
    @State private var moveCursorToEndRequest: UUID?

    private var canSend: Bool {
        !isTranscribing && !voice.isRecording && draft.hasContent
    }

    private var canRecord: Bool {
        !isTranscribing && !voice.isRecording
    }

    private var placeholder: String {
        if isTranscribing { return "Transcribing…" }
        if let hint = replyHint, !hint.isEmpty { return hint }
        return "Message Doit"
    }

    private var pickerActive: Bool {
        guard let query = mentionQuery, !availableReferences.isEmpty else {
            return false
        }
        let q = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return availableReferences.contains {
            $0.displayTitle.lowercased().contains(q)
        }
    }

    private var horizontalPadding: CGFloat {
        isExpanded ? 12 : 28
    }

    private var bottomPadding: CGFloat {
        isExpanded ? 12 : -4
    }

    private var isExpanded: Bool {
        isFocused || voice.isRecording || isTranscribing
    }

    var body: some View {
        VStack(spacing: 8) {
            if pickerActive, let query = mentionQuery {
                MentionPickerOverlay(
                    query: query,
                    candidates: availableReferences,
                    onSelect: insertReference
                )
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let voiceError {
                Text(voiceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            if voice.isRecording {
                recordingPill
            } else if isTranscribing {
                transcribingPill
            } else {
                inputBar
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, bottomPadding)
        .animation(.smooth(duration: 0.2), value: canSend)
        .animation(.smooth(duration: 0.2), value: pickerActive)
        .animation(.smooth(duration: 0.24), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            onFocusChange(focused)
        }
        .onChange(of: pendingInsertion) { _, request in
            // When the parent stages an insertion, automatically
            // focus the field so the keyboard pops and the cursor
            // sits next to the freshly-inserted pill.
            if request != nil, !isFocused {
                isFocused = true
            }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoSelections,
            maxSelectionCount: max(1, maxNewAttachments),
            matching: .images,
            photoLibrary: .shared()
        )
        .onDisappear {
            voice.cancel()
        }
    }

    private var inputBar: some View {
        Group {
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                    .disabled(!canAddMoreAttachments)
                    .opacity(canAddMoreAttachments ? 1 : 0.4)

                MentionTextView(
                    draft: $draft,
                    pendingInsertion: $pendingInsertion,
                    isFocused: $isFocused,
                    mentionQuery: $mentionQuery,
                    placeholder: placeholder,
                    isEnabled: true,
                    moveCursorToEndRequest: moveCursorToEndRequest
                )

                trailingActionButton
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var trailingActionButton: some View {
        if canSend {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send")
        } else {
            Button {
                playLightHaptic()
                Task { await startRecording() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canRecord ? Color.black : Color.primary.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canRecord)
            .accessibilityLabel("Record voice message")
        }
    }

    private var recordingPill: some View {
        HStack(spacing: 12) {
            Button {
                playLightHaptic()
                cancelRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.gray)
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            WaveformView(levels: voice.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 36)

            Button {
                playLightHaptic()
                Task { await acceptRecording() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.30), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use recording")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white, in: Capsule())
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var transcribingPill: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.primary)
                .frame(width: 40, height: 40)
            Text("Transcribing…")
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white, in: Capsule())
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .transition(.opacity)
    }

    private func insertReference(_ ref: ArtifactReference) {
        draft = draft.replacingActiveMentionQuery(mentionQuery, with: ref)
        mentionQuery = nil
        isFocused = true
    }

    private func submit() {
        let text = draft.serialized
        guard !text.isEmpty else { return }
        onSend(text)
        draft = .empty
        mentionQuery = nil
        isFocused = false
    }

    private func playLightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startRecording() async {
        voiceError = nil
        mentionQuery = nil
        isFocused = false
        do {
            try await voice.start()
        } catch {
            voiceError = error.localizedDescription
        }
    }

    private func cancelRecording() {
        voice.cancel()
        isFocused = true
    }

    private func acceptRecording() async {
        guard let url = voice.stop() else {
            isFocused = true
            return
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let text = try await TranscriptionAPI.transcribe(fileURL: url)
            draft = draft.appendingPlainText(text)
            mentionQuery = nil
            voiceError = nil
            moveCursorToEndRequest = UUID()
            isFocused = true
        } catch {
            voiceError = error.localizedDescription
            isFocused = true
        }
    }

    private var attachMenu: some View {
        Menu {
            Button {
                onTakePhoto()
            } label: {
                Label("Take photo", systemImage: "camera.fill")
            }
            Button {
                showPhotosPicker = true
            } label: {
                Label("Choose from library", systemImage: "photo.on.rectangle")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .accessibilityLabel("Attach photo")
    }
}
