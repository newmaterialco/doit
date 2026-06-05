import SwiftUI
import UIKit

// MARK: - Reference

/// Snapshot of a `TodoArtifact` shaped for the chat composer. We keep
/// just the bits we need (id for dedupe, title for display, slug for
/// the connection logo, optional URL for markdown links) so a pill
/// stays stable in the field even if the underlying artifact row
/// mutates or disappears mid-chat.
struct ArtifactReference: Identifiable, Equatable, Hashable {
    let id: UUID
    let title: String
    let providerSlug: String?
    let url: URL?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Title clamped to a length the inline pill can render without
    /// overflowing the composer line. Long Google Doc / Sheet names
    /// get an ellipsis tail rather than wrapping inside the bubble.
    var pillTitle: String {
        let trimmed = displayTitle
        let limit = 32
        if trimmed.count > limit {
            return String(trimmed.prefix(limit - 1)) + "…"
        }
        return trimmed
    }

    /// Markdown-friendly form Hermes consumes. URL-bearing references
    /// turn into a markdown link so the agent can act on them; refs
    /// without a URL fall back to a quoted title so the agent still
    /// sees what the user pointed to.
    var markdown: String {
        if let url {
            return "[\(displayTitle)](\(url.absoluteString))"
        }
        return "“\(displayTitle)”"
    }
}

extension ArtifactReference {
    /// Build a reference from a `TodoArtifact` for use inside the
    /// composer. Returns `nil` for kinds where a textual reference
    /// doesn't make sense (audio playback, malformed payloads).
    nonisolated init?(artifact: TodoArtifact) {
        switch artifact.kind {
        case .link:
            let title = artifact.title ?? artifact.url?.host ?? "Open link"
            self = ArtifactReference(
                id: artifact.id,
                title: title,
                providerSlug: artifact.provider,
                url: artifact.url
            )
        case .email:
            let draft = artifact.emailDraft
            let title = artifact.title ?? draft?.subject ?? "Sent email"
            self = ArtifactReference(
                id: artifact.id,
                title: title,
                providerSlug: artifact.emailProvider,
                url: nil
            )
        case .calendar:
            guard let event = artifact.calendarEvent else { return nil }
            self = ArtifactReference(
                id: artifact.id,
                title: artifact.title ?? event.title,
                providerSlug: "googlecalendar",
                url: event.url
            )
        case .text:
            guard !(artifact.text ?? "").isEmpty else { return nil }
            self = ArtifactReference(
                id: artifact.id,
                title: artifact.title ?? "Result",
                providerSlug: nil,
                url: nil
            )
        case .audio:
            return nil
        }
    }
}

// MARK: - Insertion request

/// Identified ping the parent uses to ask the composer to embed a
/// reference at the cursor. We key by id so re-rendering the parent
/// view doesn't reapply the same insertion twice — the textView's
/// coordinator stores the last consumed id and skips duplicates.
struct ArtifactInsertionRequest: Equatable, Identifiable {
    let id: UUID
    let reference: ArtifactReference

    init(reference: ArtifactReference) {
        self.id = UUID()
        self.reference = reference
    }
}

// MARK: - Draft

/// Composer-only draft. Tokens are either plain text spans or inline
/// artifact mentions; sending walks tokens to produce the markdown
/// body the runner persists into `todo_messages`.
struct MentionDraft: Equatable {
    var tokens: [Token]

    enum Token: Equatable {
        case text(String)
        case mention(ArtifactReference)
    }

    static let empty = MentionDraft(tokens: [])

    /// String we hand to `onSend`. Trimmed because the textView
    /// reliably appends a trailing space after pill insertion to keep
    /// the cursor typing-ready.
    var serialized: String {
        let body = tokens.map { token -> String in
            switch token {
            case .text(let value): return value
            case .mention(let ref): return ref.markdown
            }
        }
        .joined()
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasContent: Bool { !serialized.isEmpty }

    /// Replace the active typed `@query` at the end of the current
    /// draft with an inline mention. This is used by the SwiftUI picker
    /// path so tapping a row immediately updates the model, then the
    /// text view re-renders from that model.
    func replacingActiveMentionQuery(
        _ query: String?,
        with reference: ArtifactReference
    ) -> MentionDraft {
        let marker = "@" + (query ?? "")
        var updated = tokens

        for index in updated.indices.reversed() {
            guard case .text(let value) = updated[index] else {
                continue
            }
            guard value.hasSuffix(marker) else {
                continue
            }

            let prefix = String(value.dropLast(marker.count))
            var replacement: [Token] = []
            if !prefix.isEmpty {
                replacement.append(.text(prefix))
            }
            replacement.append(.mention(reference))
            replacement.append(.text(" "))
            updated.replaceSubrange(index...index, with: replacement)
            return MentionDraft(tokens: Self.normalized(updated))
        }

        var appended = updated
        if case .text(let last) = appended.last,
           !last.isEmpty,
           !last.hasSuffix(" "),
           !last.hasSuffix("\n"),
           !last.hasSuffix("\t") {
            appended.append(.text(" "))
        }
        appended.append(.mention(reference))
        appended.append(.text(" "))
        return MentionDraft(tokens: Self.normalized(appended))
    }

    func appendingPlainText(_ text: String) -> MentionDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }

        var updated = tokens
        if case .text(let last) = updated.last,
           !last.isEmpty,
           !last.hasSuffix(" "),
           !last.hasSuffix("\n"),
           !last.hasSuffix("\t") {
            updated.append(.text(" "))
        }
        updated.append(.text(trimmed))
        return MentionDraft(tokens: Self.normalized(updated))
    }

    private static func normalized(_ tokens: [Token]) -> [Token] {
        tokens.reduce(into: [Token]()) { result, token in
            switch (result.last, token) {
            case (.text(let existing), .text(let next)):
                result[result.count - 1] = .text(existing + next)
            case (_, .text(let value)) where value.isEmpty:
                break
            default:
                result.append(token)
            }
        }
    }
}

// MARK: - NSTextAttachment

/// Backing store for an inline pill in the `UITextView`. The pill
/// image is rendered from `MentionPillView` once at insertion time so
/// we don't pay layout cost on every cursor blink, and we override
/// `attachmentBounds(for:...)` to drop the pill below the baseline so
/// it sits centered on the surrounding text's x-height.
private final class MentionAttachment: NSTextAttachment {
    let reference: ArtifactReference

    init(reference: ArtifactReference, image: UIImage) {
        self.reference = reference
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    required init?(coder: NSCoder) {
        fatalError("MentionAttachment(coder:) not implemented")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let image else { return .zero }
        // Drop the pill so its visual center lines up with x-height
        // rather than hanging above the cap line.
        let descent = max(0, (image.size.height - lineFrag.height) / 2 + 1)
        return CGRect(
            x: 0,
            y: -descent,
            width: image.size.width,
            height: image.size.height
        )
    }
}

// MARK: - Pill view

/// UIKit pill rendered into a `UIImage` for `MentionAttachment`.
/// Layout: leading provider logo (or generic glyph fallback), trailing
/// truncated title; capsule background. Kept private so SwiftUI
/// callers go through `MentionTextView` and never see UIKit chrome.
private final class MentionPillView: UIView {
    init(reference: ArtifactReference, font: UIFont) {
        super.init(frame: .zero)
        backgroundColor = UIColor.systemGray5
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let icon = UIImageView()
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let slug = reference.providerSlug,
           !slug.isEmpty,
           let image = UIImage(named: slug) {
            icon.image = image
        } else {
            icon.image = UIImage(systemName: "doc.text.fill")
            icon.tintColor = .secondaryLabel
        }
        let iconSize: CGFloat = 12
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize)
        ])
        stack.addArrangedSubview(icon)

        let label = UILabel()
        label.font = font
        label.textColor = UIColor.label
        label.text = reference.pillTitle
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("MentionPillView(coder:) not implemented")
    }

    /// Render the pill to a `UIImage` we can host inside an
    /// `NSTextAttachment`. Sized to the natural compressed fit.
    static func render(for reference: ArtifactReference, font: UIFont) -> UIImage {
        let pill = MentionPillView(reference: reference, font: font)
        var target = pill.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required
        )
        if target.width <= 1 || target.height <= 1 {
            let titleWidth = (reference.pillTitle as NSString).size(
                withAttributes: [.font: font]
            ).width
            target = CGSize(
                width: min(max(titleWidth + 36, 56), 220),
                height: 22
            )
        }
        pill.frame = CGRect(origin: .zero, size: target)
        pill.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { ctx in
            pill.layer.render(in: ctx.cgContext)
        }
    }
}

// MARK: - Backing UITextView

/// `UITextView` subclass that hosts a placeholder label and self-
/// manages its intrinsic content size so the SwiftUI parent can grow
/// the field with content (and cap it at a sensible max line count).
final class MentionTextViewBacking: UITextView {
    let placeholderLabel = UILabel()
    /// Cap the auto-growing height; once content exceeds this, we
    /// flip `isScrollEnabled = true` so the user can scroll within
    /// a fixed-height box instead of pushing the chat off-screen.
    var maxAutoHeight: CGFloat = 130

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configurePlaceholder()
    }

    required init?(coder: NSCoder) {
        fatalError("MentionTextViewBacking(coder:) not implemented")
    }

    private func configurePlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
        placeholderLabel.font = self.font
        addSubview(placeholderLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let leading = textContainerInset.left + self.textContainer.lineFragmentPadding
        let top = textContainerInset.top
        let trailing = textContainerInset.right + self.textContainer.lineFragmentPadding
        placeholderLabel.frame = CGRect(
            x: leading,
            y: top,
            width: max(0, bounds.width - leading - trailing),
            height: placeholderLabel.intrinsicContentSize.height
        )
        invalidateIntrinsicContentSize()
    }

    override var font: UIFont? {
        didSet { placeholderLabel.font = font }
    }

    override var intrinsicContentSize: CGSize {
        let minHeight: CGFloat = 38
        guard bounds.width > 0 else {
            isScrollEnabled = false
            return CGSize(width: UIView.noIntrinsicMetric, height: minHeight)
        }
        let target = sizeThatFits(CGSize(width: bounds.width,
                                         height: .greatestFiniteMagnitude))
        if target.height > maxAutoHeight {
            isScrollEnabled = true
            return CGSize(width: UIView.noIntrinsicMetric, height: maxAutoHeight)
        }
        isScrollEnabled = false
        return CGSize(width: UIView.noIntrinsicMetric,
                      height: max(target.height, minHeight))
    }
}

// MARK: - SwiftUI wrapper

/// Composer text input that supports inline artifact pills. Edits
/// flow through the coordinator into a `MentionDraft` binding; the
/// parent serializes to markdown on send.
struct MentionTextView: UIViewRepresentable {
    @Binding var draft: MentionDraft
    @Binding var pendingInsertion: ArtifactInsertionRequest?
    @Binding var isFocused: Bool
    @Binding var mentionQuery: String?
    let placeholder: String
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MentionTextViewBacking {
        let tv = MentionTextViewBacking()
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        let font = UIFont.systemFont(ofSize: 16)
        tv.font = font
        tv.placeholderLabel.font = font
        tv.placeholderLabel.text = placeholder
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        tv.textContainer.lineFragmentPadding = 0
        tv.tintColor = UIColor.tintColor
        tv.returnKeyType = .default
        tv.enablesReturnKeyAutomatically = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tv
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MentionTextViewBacking,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let target = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let height = min(max(target.height, 38), uiView.maxAutoHeight)
        uiView.isScrollEnabled = target.height > uiView.maxAutoHeight
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ uiView: MentionTextViewBacking, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        uiView.placeholderLabel.text = placeholder
        uiView.isEditable = isEnabled
        uiView.isUserInteractionEnabled = isEnabled

        // Sync draft → attributed text only when the model differs
        // from what the textView currently mirrors. Coordinator-
        // published edits update `lastWrittenDraft` so this branch
        // stays quiet during normal typing.
        if coord.lastWrittenDraft != draft {
            coord.applyDraft(draft, to: uiView)
        }

        // Apply pending insertion when we see a request the
        // coordinator hasn't consumed yet.
        if let request = pendingInsertion,
           coord.lastConsumedRequestID != request.id {
            coord.lastConsumedRequestID = request.id
            coord.insert(reference: request.reference, into: uiView)
        }

        // Focus management.
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }

        uiView.placeholderLabel.isHidden = !uiView.attributedText.string.isEmpty
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionTextView
        weak var textView: MentionTextViewBacking?
        var lastWrittenDraft: MentionDraft = .empty
        var lastConsumedRequestID: UUID?

        init(_ parent: MentionTextView) {
            self.parent = parent
        }

        // MARK: Apply draft

        func applyDraft(_ draft: MentionDraft, to tv: MentionTextViewBacking) {
            let font = tv.font ?? UIFont.systemFont(ofSize: 16)
            let attributed = makeAttributed(draft: draft, font: font)
            let priorRange = tv.selectedRange
            tv.attributedText = attributed
            // Keep the cursor at the end after a clear (most common
            // case); otherwise clamp the prior range to the new
            // length so the cursor never goes out of bounds.
            let length = attributed.length
            tv.selectedRange = NSRange(
                location: min(priorRange.location, length),
                length: 0
            )
            lastWrittenDraft = draft
            tv.placeholderLabel.isHidden = !attributed.string.isEmpty
            tv.invalidateIntrinsicContentSize()
        }

        private func makeAttributed(draft: MentionDraft, font: UIFont) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.label
            ]
            for token in draft.tokens {
                switch token {
                case .text(let value):
                    result.append(NSAttributedString(string: value, attributes: textAttrs))
                case .mention(let ref):
                    let img = MentionPillView.render(for: ref, font: pillFont(from: font))
                    let att = MentionAttachment(reference: ref, image: img)
                    let mention = NSMutableAttributedString(attachment: att)
                    mention.addAttributes(
                        [.font: font, .foregroundColor: UIColor.label],
                        range: NSRange(location: 0, length: mention.length)
                    )
                    result.append(mention)
                }
            }
            return result
        }

        private func pillFont(from font: UIFont) -> UIFont {
            UIFont.systemFont(ofSize: max(11, font.pointSize - 3), weight: .medium)
        }

        // MARK: Insert

        func insert(reference: ArtifactReference, into tv: MentionTextViewBacking) {
            let font = tv.font ?? UIFont.systemFont(ofSize: 16)
            let img = MentionPillView.render(for: reference, font: pillFont(from: font))
            let att = MentionAttachment(reference: reference, image: img)
            let mention = NSMutableAttributedString(attachment: att)
            // Force the surrounding text font onto the attachment
            // run so subsequent typing inherits the right styling.
            mention.addAttributes(
                [.font: font, .foregroundColor: UIColor.label],
                range: NSRange(location: 0, length: mention.length)
            )
            mention.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .foregroundColor: UIColor.label]
            ))

            let current = NSMutableAttributedString(attributedString: tv.attributedText)
            let cursor = tv.selectedRange

            if let queryRange = activeMentionRange(in: tv) {
                // Replace the active `@query` (including the leading
                // `@`) with the pill so picker selection feels like a
                // direct in-place swap.
                current.replaceCharacters(in: queryRange, with: mention)
                tv.attributedText = current
                tv.selectedRange = NSRange(
                    location: queryRange.location + mention.length,
                    length: 0
                )
            } else {
                // Insert at the caret. If we're mid-word, prepend a
                // space so the pill doesn't fuse to the previous
                // letter.
                var insertionLocation = cursor.location
                let needsLeadingSpace: Bool = {
                    guard insertionLocation > 0 else { return false }
                    let char = (current.string as NSString).substring(
                        with: NSRange(location: insertionLocation - 1, length: 1)
                    )
                    return !(char == " " || char == "\n" || char == "\t" || char == "\u{FFFC}")
                }()
                if needsLeadingSpace {
                    let lead = NSAttributedString(
                        string: " ",
                        attributes: [.font: font, .foregroundColor: UIColor.label]
                    )
                    current.insert(lead, at: insertionLocation)
                    insertionLocation += 1
                }
                let replaceRange = NSRange(
                    location: insertionLocation,
                    length: cursor.length
                )
                current.replaceCharacters(in: replaceRange, with: mention)
                tv.attributedText = current
                tv.selectedRange = NSRange(
                    location: insertionLocation + mention.length,
                    length: 0
                )
            }

            let newDraft = parent.makeDraft(from: tv.attributedText)
            lastWrittenDraft = newDraft
            DispatchQueue.main.async { [self] in
                self.parent.draft = newDraft
                self.parent.mentionQuery = nil
            }
            tv.placeholderLabel.isHidden = !tv.attributedText.string.isEmpty
            tv.invalidateIntrinsicContentSize()
            UISelectionFeedbackGenerator().selectionChanged()
        }

        // MARK: Delegate

        func textViewDidChange(_ tv: UITextView) {
            guard let backing = tv as? MentionTextViewBacking else { return }
            let newDraft = parent.makeDraft(from: tv.attributedText)
            if newDraft != lastWrittenDraft {
                lastWrittenDraft = newDraft
                parent.draft = newDraft
            }
            let query = detectMentionQuery(in: tv)
            if query != parent.mentionQuery {
                parent.mentionQuery = query
            }
            backing.placeholderLabel.isHidden = !tv.attributedText.string.isEmpty
            backing.invalidateIntrinsicContentSize()
        }

        func textView(
            _ tv: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            return true
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if !parent.isFocused {
                DispatchQueue.main.async { self.parent.isFocused = true }
            }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            if parent.isFocused {
                DispatchQueue.main.async { self.parent.isFocused = false }
            }
            if parent.mentionQuery != nil {
                DispatchQueue.main.async { self.parent.mentionQuery = nil }
            }
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            // Cursor moves can also turn the active query on/off
            // (e.g. user taps before an `@` that's already typed).
            let query = detectMentionQuery(in: tv)
            if query != parent.mentionQuery {
                DispatchQueue.main.async { self.parent.mentionQuery = query }
            }
        }

        // MARK: Mention detection

        /// Range of the active `@query` ending at the cursor, or `nil`
        /// when the cursor isn't sitting inside one. The leading `@`
        /// must come right after a whitespace, newline, attachment,
        /// or the start of the field — otherwise `foo@bar` style
        /// strings would falsely trigger the picker.
        fileprivate func activeMentionRange(in tv: UITextView) -> NSRange? {
            let plain = tv.text as NSString
            let cursor = tv.selectedRange.location
            guard cursor <= plain.length else { return nil }
            var i = cursor
            while i > 0 {
                let charRange = NSRange(location: i - 1, length: 1)
                let char = plain.substring(with: charRange)
                if char == "@" {
                    let isAtStart = (i - 1 == 0)
                    if isAtStart {
                        return NSRange(location: i - 1, length: cursor - (i - 1))
                    }
                    let prevChar = plain.substring(
                        with: NSRange(location: i - 2, length: 1)
                    )
                    if prevChar == " " || prevChar == "\n"
                        || prevChar == "\t" || prevChar == "\u{FFFC}" {
                        return NSRange(location: i - 1, length: cursor - (i - 1))
                    }
                    return nil
                }
                if char == " " || char == "\n"
                    || char == "\t" || char == "\u{FFFC}" {
                    return nil
                }
                i -= 1
            }
            return nil
        }

        fileprivate func detectMentionQuery(in tv: UITextView) -> String? {
            guard let range = activeMentionRange(in: tv), range.length > 0
            else { return nil }
            let plain = tv.text as NSString
            // Strip the leading `@` so callers filter on the query.
            let trimmed = NSRange(
                location: range.location + 1,
                length: range.length - 1
            )
            return plain.substring(with: trimmed)
        }
    }

    /// Walk the textView's attributed text into a `MentionDraft`,
    /// merging consecutive `.text` runs so the model stays compact.
    fileprivate func makeDraft(from attributed: NSAttributedString) -> MentionDraft {
        var tokens: [MentionDraft.Token] = []
        let plain = attributed.string as NSString
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            if let mention = value as? MentionAttachment {
                tokens.append(.mention(mention.reference))
                return
            }
            let snippet = plain.substring(with: range)
            guard !snippet.isEmpty else { return }
            if case .text(let last) = tokens.last {
                tokens[tokens.count - 1] = .text(last + snippet)
            } else {
                tokens.append(.text(snippet))
            }
        }
        return MentionDraft(tokens: tokens)
    }
}

// MARK: - Picker overlay

/// Floating list shown above the composer while an `@query` is active.
/// Filters `candidates` by display title and keeps the result scrollable
/// when a task has many artifacts.
struct MentionPickerOverlay: View {
    let query: String
    let candidates: [ArtifactReference]
    let onSelect: (ArtifactReference) -> Void

    private let maxPickerHeight: CGFloat = 220

    private var filtered: [ArtifactReference] {
        let q = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [ArtifactReference]
        if q.isEmpty {
            matches = candidates
        } else {
            matches = candidates.filter {
                $0.displayTitle.lowercased().contains(q)
            }
        }
        return matches
    }

    var body: some View {
        if filtered.isEmpty {
            EmptyView()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, ref in
                        Button {
                            onSelect(ref)
                        } label: {
                            row(for: ref)
                        }
                        .buttonStyle(.plain)
                        if index < filtered.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxPickerHeight, alignment: .leading)
            .scrollIndicators(.visible)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        }
    }

    @ViewBuilder
    private func row(for ref: ArtifactReference) -> some View {
        HStack(spacing: 10) {
            Group {
                if let slug = ref.providerSlug, !slug.isEmpty {
                    ConnectionLogo(slug: slug)
                } else {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            Text(ref.displayTitle)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}
