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
}

/// Bottom panel of the split-screen detail view: a scrolling conversation
/// of `ConversationItem`s plus a live composer. Free-form sends go through
/// `onSend`; the composer disables itself while the agent is active so the
/// user can't queue messages on top of an in-flight Hermes turn.
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
    let isAgentRunning: Bool

    @Binding var photoSelections: [PhotosPickerItem]
    let canAddMoreAttachments: Bool
    let maxNewAttachments: Int
    let onTakePhoto: () -> Void
    let onRemoveAttachment: (TodoAttachment) -> Void
    let onPreviewAttachment: (TodoAttachment) -> Void
    let onOpenOAuth: (URL) -> Void
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

    /// Current keyboard overlap (in points) over the chat panel. Driven
    /// by `keyboardWillChangeFrameNotification`; we apply it as bottom
    /// padding so the composer rides above the keyboard inside the
    /// vendor split's `.ignoresSafeArea()` bottom wrapper.
    @State private var keyboardLift: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().opacity(0.5)
            ChatComposer(
                photoSelections: $photoSelections,
                canAddMoreAttachments: canAddMoreAttachments,
                maxNewAttachments: maxNewAttachments,
                isAgentRunning: isAgentRunning,
                replyHint: composerReplyHint,
                onTakePhoto: onTakePhoto,
                onSend: onSend,
                onFocusChange: onFocusChange
            )
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatStyle.messageSpacing) {
                    ForEach(items) { item in
                        messageRow(for: item)
                            .id(item.id)
                            .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 8)
                        .id("__bottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // iMessage-style drag-to-dismiss. `.interactively` follows
            // the finger so the keyboard slides away under the user's
            // gesture instead of popping; once focus drops, our
            // `onFocusChange` hook restores the prior split detent.
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
            .onChange(of: items.count) { _, _ in
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo("__bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("__bottom", anchor: .bottom)
            }
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
                onRemove: onRemoveAttachment,
                onTap: onPreviewAttachment
            )
        case .userMessage(_, let text, _):
            UserTextBubble(text: text)
        case .agentStep(let step):
            AgentStepMessage(step: step, onOpenOAuth: onOpenOAuth)
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
            Text(text)
                .font(.system(size: ChatStyle.messageFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(Color.primary)
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

private struct UserAttachmentsBubble: View {
    let attachments: [TodoAttachment]
    let urls: [UUID: URL]
    let onRemove: (TodoAttachment) -> Void
    let onTap: (TodoAttachment) -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        RemoteAttachmentTile(
                            signedURL: urls[attachment.id],
                            onRemove: { onRemove(attachment) },
                            onTap: { onTap(attachment) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 280, alignment: .trailing)
        }
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
    let step: TodoStep
    let onOpenOAuth: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let toolName = step.tool_name, !toolName.isEmpty {
                Text(prettify(toolName))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let text = step.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: ChatStyle.messageFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if step.kind == .oauth_needed,
               let urlStr = step.url,
               let url = URL(string: urlStr) {
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
            Text(step.ts.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(interaction.prompt)
                .font(.system(size: ChatStyle.messageFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let draft = interaction.emailDraft {
                EmailDraftPreview(draft: draft)
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
            Text(summary ?? "Ready when you are.")
                .font(.system(size: ChatStyle.messageFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

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
        Text(text)
            .font(.system(size: ChatStyle.messageFontSize, weight: .regular, design: .rounded))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Composer

/// Live chat composer. Text + send fire `onSend` with the trimmed draft;
/// the field and send button auto-disable while the agent is mid-turn so
/// the user can't pile messages on top of an in-flight Hermes run. The
/// paperclip menu remains available for attachments regardless of agent
/// state — uploads always work because they don't bother the agent.
///
/// `onFocusChange` is forwarded out so the parent (TodoDetailView) can
/// snap the vertical split to `.bottomFull` while the field is focused
/// and restore the prior detent on blur. Doing this at the parent keeps
/// the composer view itself unaware of the split layout.
private struct ChatComposer: View {
    @Binding var photoSelections: [PhotosPickerItem]
    let canAddMoreAttachments: Bool
    let maxNewAttachments: Int
    let isAgentRunning: Bool
    /// Open-interaction prompt hint (e.g. "Example: Wednesday at 3pm…").
    /// When present we surface it as the placeholder so the user knows
    /// the composer is the way to answer the agent's pending question.
    let replyHint: String?
    let onTakePhoto: () -> Void
    let onSend: (String) -> Void
    let onFocusChange: (Bool) -> Void

    @State private var draft: String = ""
    @State private var showPhotosPicker = false
    @FocusState private var focused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !isAgentRunning && !trimmedDraft.isEmpty
    }

    private var placeholder: String {
        if isAgentRunning { return "Hermes is working…" }
        if let hint = replyHint, !hint.isEmpty { return hint }
        return "Message Doit"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            attachMenu
                .disabled(!canAddMoreAttachments)
                .opacity(canAddMoreAttachments ? 1 : 0.4)

            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .focused($focused)
                .disabled(isAgentRunning)
                .submitLabel(.send)
                .onSubmit(submit)
                // Multiline TextFields ignore `.onSubmit` on iOS — Return
                // always inserts `\n`. Intercept a trailing newline (the
                // keyboard's blue send arrow) and route it to `submit`
                // instead so Return behaves like every other chat app.
                .onChange(of: draft) { _, newValue in
                    guard newValue.hasSuffix("\n") else { return }
                    draft = String(newValue.dropLast())
                    submit()
                }

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        (canSend ? Color.accentColor : Color.primary.opacity(0.4)),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .animation(.smooth(duration: 0.2), value: canSend)
        .animation(.smooth(duration: 0.2), value: isAgentRunning)
        .onChange(of: focused) { _, isFocused in
            onFocusChange(isFocused)
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoSelections,
            maxSelectionCount: max(1, maxNewAttachments),
            matching: .images,
            photoLibrary: .shared()
        )
    }

    private func submit() {
        let text = trimmedDraft
        guard !text.isEmpty, !isAgentRunning else { return }
        onSend(text)
        draft = ""
        focused = false
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
            Image(systemName: "paperclip")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .accessibilityLabel("Attach photo")
    }
}
