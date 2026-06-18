import SwiftUI

/// Renders agent/user copy with inline markdown (bold, italic, links) and
/// auto-linked bare URLs. Used in chat bubbles and text artifact cards.
struct MarkdownMessageText: View {
    let text: String
    var foregroundColor: Color = .primary
    var fontSize: CGFloat = 17

    var body: some View {
        Text(attributedText)
            .font(.system(size: fontSize, weight: .regular, design: .rounded))
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
