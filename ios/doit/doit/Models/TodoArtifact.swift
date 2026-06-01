import Foundation

/// Kinds of agent-produced artifacts the iOS detail view knows how to
/// render. Anything outside this set is dropped by the runner's parser
/// (`parse_artifacts` in `runner/runner/events.py`) so we never store rows
/// the UI can't display.
enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case link
    case email
    case calendar
    case text
}

/// One user-visible deliverable produced by the agent — a created Google
/// Sheet/Doc link, a sent email summary, a calendar invite, or a short
/// text result. Multiple artifacts can sit on a single todo and the agent
/// is allowed to update one in place by re-emitting it with the same
/// `artifact_key`.
///
/// The shape of `payload` depends on `kind`; the computed accessors below
/// pull common fields out so call sites don't have to dig through the
/// `JSONValue` tree.
struct TodoArtifact: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let todo_id: UUID
    let user_id: UUID
    let artifact_key: String
    let kind: ArtifactKind
    let title: String?
    let payload: JSONValue?
    let hermes_run_id: String?
    let created_at: Date
    let updated_at: Date

    // MARK: - Shared helpers

    /// Convenience accessor for the payload's top-level object, since
    /// every render path needs it.
    private var object: [String: JSONValue]? { payload?.objectValue }

    /// Truthy when the artifact has at least enough data to render
    /// something useful. Used to defensively skip empty rows.
    var hasContent: Bool {
        switch kind {
        case .link: return url != nil
        case .email: return emailDraft != nil
        case .calendar: return calendarEvent != nil
        case .text: return !(text ?? "").isEmpty
        }
    }

    // MARK: - link

    /// `payload.url` parsed as a `URL` for link artifacts (and used as the
    /// "open in browser" target for calendar artifacts that also carry
    /// one).
    var url: URL? {
        guard let raw = object?["url"]?.stringValue else { return nil }
        return URL(string: raw)
    }

    /// Toolkit slug the link came from (e.g. `googlesheets`, `googledocs`,
    /// `gmail`). Drives the small leading icon on the link card; falls
    /// back to a generic glyph when absent.
    var provider: String? {
        object?["provider"]?.stringValue
    }

    /// Composio slug for email drafts (defaults to `gmail`).
    var emailProvider: String {
        let raw = object?["provider"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw.lowercased() }
        return "gmail"
    }

    // MARK: - email

    /// `(subject, body, to)` triple for email artifacts. Returns nil when
    /// the payload doesn't look like a structured draft, so call sites can
    /// fall back to a generic renderer.
    var emailDraft: (subject: String, body: String, to: [String])? {
        guard let obj = object else { return nil }
        guard let subject = obj["subject"]?.stringValue,
              let body = obj["body"]?.stringValue else { return nil }
        let to = obj["to"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        return (subject: subject, body: body, to: to)
    }

    // MARK: - calendar

    /// Parsed view of a calendar artifact. `start`/`end` are decoded from
    /// ISO 8601 strings; both are optional so a half-specified event
    /// still renders the parts it does have.
    struct CalendarEvent: Hashable, Sendable {
        let title: String
        let start: Date?
        let end: Date?
        let location: String?
        let attendees: [String]
        let url: URL?
    }

    var calendarEvent: CalendarEvent? {
        guard let obj = object else { return nil }
        let title = obj["title"]?.stringValue ?? self.title
        guard let title, !title.isEmpty else { return nil }
        let attendees = obj["attendees"]?.arrayValue?
            .compactMap { $0.stringValue } ?? []
        let urlValue = obj["url"]?.stringValue.flatMap(URL.init(string:))
        return CalendarEvent(
            title: title,
            start: obj["start"]?.stringValue.flatMap(Self.parseISO8601),
            end: obj["end"]?.stringValue.flatMap(Self.parseISO8601),
            location: obj["location"]?.stringValue,
            attendees: attendees,
            url: urlValue
        )
    }

    // MARK: - text

    /// Plain-text body for `kind == .text` artifacts.
    var text: String? { object?["text"]?.stringValue }

    // MARK: - Internals

    /// ISO 8601 parser that accepts both the fractional-second variant
    /// (`2025-06-01T12:00:00.000Z`) and the plain one (`2025-06-01T12:00:00Z`).
    /// Returns nil when neither shape matches; callers render the raw
    /// string as a fallback when this happens.
    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
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

// MARK: - Detail header layout

extension TodoArtifact {
    /// Primary deliverables (sheet, doc, calendar, text) first; email drafts
    /// grouped underneath so the header reads as a drill-down.
    static func groupedForDisplay(
        _ artifacts: [TodoArtifact]
    ) -> (primary: [TodoArtifact], emailDrafts: [TodoArtifact]) {
        let sorted = artifacts.sorted {
            if $0.created_at != $1.created_at { return $0.created_at < $1.created_at }
            return $0.artifact_key < $1.artifact_key
        }
        let primary = sorted.filter { $0.kind != .email }
        let emails = sorted.filter { $0.kind == .email }
        return (primary, emails)
    }

    /// Connection logos for the metadata row: prep slug first, then providers
    /// discovered from artifacts as the task progresses.
    static func connectionSlugs(
        todoSlug: String?,
        artifacts: [TodoArtifact]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func add(_ raw: String?) {
            guard let raw else { return }
            let slug = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !slug.isEmpty, !seen.contains(slug) else { return }
            seen.insert(slug)
            result.append(slug)
        }

        add(todoSlug)
        let (primary, emails) = groupedForDisplay(artifacts)
        for artifact in primary {
            add(artifact.provider)
        }
        for artifact in emails {
            add(artifact.emailProvider)
        }
        return result
    }
}
