import SwiftUI

/// Shared layout constants for the title column, checkmark gutter, and
/// metadata row inset so the date and downstream cards line up with the
/// task title instead of the leading checkmark circle.
private enum TaskHeaderLayout {
    static let statusIconSize: CGFloat = 28
    static let statusIconSpacing: CGFloat = 12
    static var titleLeadingInset: CGFloat { statusIconSize + statusIconSpacing }
    /// Extra trailing inset on the date / connection row beyond the
    /// container's horizontal padding so the logo doesn't hug the edge.
    static let metadataExtraTrailingPadding: CGFloat = 8
    static let connectorCornerRadius: CGFloat = 8
    /// Space between the horizontal connector stub and the component edge.
    static let connectorComponentGap: CGFloat = 8
}

/// Top panel of the split-screen detail view: a back chevron pinned to the
/// top-left (so navigation mirrors the system nav bar), a more-actions
/// (`ellipsis`) menu on the right that exposes "Stop task" while the agent
/// is still cancellable, and a compact status indicator + title + status
/// label below with extra breathing room from the action row.
struct TaskHeaderView: View {
    let todo: Todo
    /// User-visible deliverables produced by the agent (e.g. a created
    /// Google Sheet link, a sent email summary, a calendar invite). Each
    /// renders as a compact card under the title. Empty by default so
    /// older callers and previews don't need to plumb anything through.
    let artifacts: [TodoArtifact]
    /// Short blurb describing what the agent is currently working on or
    /// waiting on — sourced from the open interaction's `summary`.
    /// Rendered under the title in a dashed-border card so it reads as
    /// a status note (not as part of the chat). `nil` when there's
    /// nothing to surface.
    let agentStatus: String?
    let onBack: () -> Void
    let onDelete: () -> Void

    /// Vertical position (in `TaskHeaderTitleBlock` space) where the
    /// connector bends into the first attached component — measured from
    /// the component's midline via `ConnectorBendYKey`.
    @State private var connectorBendY: CGFloat = 0

    /// Explicit memberwise init so Xcode's incremental compiler can't
    /// keep a stale synthesized signature around when this view's
    /// surface changes — once bit me with "Extra argument 'agentStatus'
    /// in call" after editing the property list. Defaults keep older
    /// call sites and previews terse.
    init(
        todo: Todo,
        artifacts: [TodoArtifact] = [],
        agentStatus: String? = nil,
        onBack: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.todo = todo
        self.artifacts = artifacts
        self.agentStatus = agentStatus
        self.onBack = onBack
        self.onDelete = onDelete
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")

                    Spacer(minLength: 8)

                    Text(todo.status.label)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.3), value: todo.status)
                        .accessibilityLabel("Status: \(todo.status.label)")

                    Spacer(minLength: 8)

                    Menu {
                        Button("Delete Task", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    // Suppress Menu's default accent (blue) tint so the
                    // ellipsis renders in the same neutral grey as the back
                    // chevron's symbol.
                    .buttonStyle(.plain)
                    .accessibilityLabel("More options")
                }

                // Metadata row: date aligns with the title column; connection
                // logo sits further in from the trailing edge.
                HStack(alignment: .center, spacing: 8) {
                    Text(humanizedDate(todo.created_at))
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    connectionLogosRow
                }
                .padding(.leading, TaskHeaderLayout.titleLeadingInset)
                .padding(.trailing, TaskHeaderLayout.metadataExtraTrailingPadding)
                .padding(.top, 12)

                taskTitleBlock
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.3), value: agentStatus)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var connectionSlugs: [String] {
        TodoArtifact.connectionSlugs(todoSlug: todo.connection_slug, artifacts: artifacts)
    }

    @ViewBuilder
    private var connectionLogosRow: some View {
        ConnectionLogosRow(slugs: connectionSlugs)
    }

    private var hasContentBelowTitle: Bool {
        if let status = agentStatus, !status.isEmpty { return true }
        return !artifacts.isEmpty
    }

    /// Checkmark, title, and any agent-status / artifact cards share one
    /// row so a timeline connector can descend from the icon and curve into
    /// the title-aligned content below.
    @ViewBuilder
    private var taskTitleBlock: some View {
        HStack(alignment: .top, spacing: TaskHeaderLayout.statusIconSpacing) {
            StatusIndicatorIcon(status: todo.status)
                .frame(
                    width: TaskHeaderLayout.statusIconSize,
                    height: TaskHeaderLayout.statusIconSize
                )

            VStack(alignment: .leading, spacing: 16) {
                Text(todo.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if let status = agentStatus, !status.isEmpty {
                    agentStatusBox(text: status)
                        .connectorAnchor()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !artifacts.isEmpty {
                    artifactsSection(anchorFirst: agentStatus?.isEmpty != false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: "TaskHeaderTitleBlock")
        .onPreferenceChange(ConnectorBendYKey.self) { bendY in
            connectorBendY = bendY
        }
        .background {
            if hasContentBelowTitle,
               connectorBendY > TaskHeaderLayout.statusIconSize {
                GeometryReader { proxy in
                    TaskHeaderConnectorShape(
                        iconCenterX: TaskHeaderLayout.statusIconSize / 2,
                        contentLeadingX: TaskHeaderLayout.titleLeadingInset,
                        iconBottomY: TaskHeaderLayout.statusIconSize,
                        bendY: connectorBendY,
                        cornerRadius: TaskHeaderLayout.connectorCornerRadius,
                        componentGap: TaskHeaderLayout.connectorComponentGap
                    )
                    .stroke(
                        Color.secondary.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    /// "Waiting on you" status card: dashed rounded border, a small
    /// leading sparkle icon to signal that this is the agent's current
    /// thought, and the summary text wrapping as many lines as needed.
    /// Designed to fade in when the interaction opens and out when the
    /// user answers — the parent animates on `agentStatus` changes.
    @ViewBuilder
    private func agentStatusBox(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
    }

    /// One card per artifact stacked vertically. Lives just below the
    /// title so the deliverable sits next to the task it answers; the
    /// surrounding `ScrollView` lets the header expand when there are
    /// multiple artifacts without squeezing the chat panel.
    @ViewBuilder
    private func artifactsSection(anchorFirst: Bool) -> some View {
        let grouped = TodoArtifact.groupedForDisplay(artifacts)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(grouped.primary.enumerated()), id: \.element.id) { index, artifact in
                TaskArtifactView(artifact: artifact)
                    .modifier(ConditionalConnectorAnchor(isActive: anchorFirst && index == 0))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !grouped.emailDrafts.isEmpty {
                emailDraftsSection(
                    drafts: grouped.emailDrafts,
                    anchorFirst: anchorFirst && grouped.primary.isEmpty
                )
            }
        }
        .animation(.smooth(duration: 0.25), value: artifacts.map(\.id))
        .padding(.top, 4)
    }

    @ViewBuilder
    private func emailDraftsSection(
        drafts: [TodoArtifact],
        anchorFirst: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ConnectionLogo(slug: drafts.first?.emailProvider ?? "gmail")
                    .frame(width: 16, height: 16)
                Text(drafts.count == 1 ? "Draft email" : "Draft emails (\(drafts.count))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, artifact in
                    TaskArtifactView(artifact: artifact)
                        .modifier(ConditionalConnectorAnchor(isActive: anchorFirst && index == 0))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 2)
            }
        }
    }

    /// Formats a creation timestamp the way iOS apps usually do — anchored
    /// to "Today" / "Yesterday" while the memory is still fresh, sliding
    /// into weekday names within the past week, then to month-day, and
    /// finally to month-day-year for older items. Always pairs the day
    /// part with a short time (`3:42 PM`).
    private func humanizedDate(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let timeStr = date.formatted(date: .omitted, time: .shortened)

        if cal.isDateInToday(date) {
            return "Today at \(timeStr)"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday at \(timeStr)"
        }
        if let days = cal.dateComponents([.day], from: date, to: now).day,
           days >= 0, days < 7 {
            let weekday = date.formatted(.dateTime.weekday(.wide))
            return "\(weekday) at \(timeStr)"
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            let monthDay = date.formatted(.dateTime.month(.abbreviated).day())
            return "\(monthDay) at \(timeStr)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
            + " at \(timeStr)"
    }
}

/// Lightweight todo-checkbox style indicator: an unchecked circle for every
/// non-terminal state (subtly pulsing while the agent is actively working)
/// and a green filled checkmark once the task is done. Failure / auth /
/// input states intentionally stay as the unchecked circle — those are
/// already communicated by the status label below the title and the pill.
struct StatusIndicatorIcon: View {
    let status: TodoStatus

    var body: some View {
        Image(systemName: status == .done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(status == .done ? Color.green : Color.secondary)
            .symbolEffect(.pulse, isActive: status.isActive)
    }
}

/// Timeline stroke from the checkmark column toward attached content:
/// vertical under the icon, a rounded 90° corner, then a straight
/// horizontal stub that stops short of the component.
private struct TaskHeaderConnectorShape: Shape {
    var iconCenterX: CGFloat
    var contentLeadingX: CGFloat
    var iconBottomY: CGFloat
    var bendY: CGFloat
    var cornerRadius: CGFloat
    var componentGap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius
        let y = min(max(bendY, iconBottomY + r + 1), rect.maxY)
        let horizontalEndX = contentLeadingX - componentGap

        path.move(to: CGPoint(x: iconCenterX, y: iconBottomY))
        path.addLine(to: CGPoint(x: iconCenterX, y: y - r))
        path.addArc(
            center: CGPoint(x: iconCenterX + r, y: y - r),
            radius: r,
            startAngle: .radians(.pi),
            endAngle: .radians(.pi / 2),
            clockwise: true
        )
        if horizontalEndX > iconCenterX + r {
            path.addLine(to: CGPoint(x: horizontalEndX, y: y))
        }
        return path
    }
}

/// Reports the vertical midpoint of the first attached component so the
/// connector knows where to bend into it.
private struct ConnectorBendYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct ConnectorAnchorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: ConnectorBendYKey.self,
                    value: geo.frame(in: .named("TaskHeaderTitleBlock")).midY
                )
            }
        }
    }
}

private struct ConditionalConnectorAnchor: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.modifier(ConnectorAnchorModifier())
        } else {
            content
        }
    }
}

private extension View {
    func connectorAnchor() -> some View {
        modifier(ConnectorAnchorModifier())
    }
}

// MARK: - Artifact card

/// Compact card the agent uses to surface a final deliverable — a created
/// doc/sheet link, a sent email, a calendar invite, or a text result.
/// Dispatches on `artifact.kind` to one of four small renderers; unknown
/// or empty payloads short-circuit to nothing so a malformed row never
/// leaves a blank tile in the header.
struct TaskArtifactView: View {
    let artifact: TodoArtifact

    var body: some View {
        Group {
            switch artifact.kind {
            case .link: LinkArtifactCard(artifact: artifact)
            case .email: EmailArtifactCard(artifact: artifact)
            case .calendar: CalendarArtifactCard(artifact: artifact)
            case .text: TextArtifactCard(artifact: artifact)
            }
        }
    }
}

/// Common visual shell every artifact card uses: rounded background, a
/// small leading icon, a title row, and a slot for kind-specific content.
/// Pulled out so the four renderers don't each re-implement the chrome.
private struct ArtifactCardShell<Content: View>: View {
    let icon: AnyView
    let title: String
    let trailing: AnyView?
    let onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    init(
        icon: AnyView,
        title: String,
        trailing: AnyView? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.trailing = trailing
        self.onTap = onTap
        self.content = content
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                icon
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                trailing
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )

        if let onTap {
            Button(action: onTap) { card }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            card
        }
    }
}

/// Open-in-browser card for `link` artifacts. The leading glyph is the
/// provider's `ConnectionLogo` when we have a slug for it (gmail,
/// googlesheets, googledocs, …) and a generic link symbol otherwise.
private struct LinkArtifactCard: View {
    let artifact: TodoArtifact
    @Environment(\.openURL) private var openURL

    var body: some View {
        let title = artifact.title ?? artifact.url?.host ?? "Open link"
        let url = artifact.url
        let tap: (() -> Void)? = url.map { target in
            { openURL(target) }
        }
        ArtifactCardShell(
            icon: AnyView(providerIcon),
            title: title,
            trailing: AnyView(
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            ),
            onTap: tap
        ) {
            if let host = url?.host {
                Text(host)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let slug = artifact.provider, !slug.isEmpty {
            ConnectionLogo(slug: slug)
        } else {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}

/// Email draft preview: To/Subject in the header, body truncated below.
private struct EmailArtifactCard: View {
    let artifact: TodoArtifact

    var body: some View {
        let draft = artifact.emailDraft
        let title = artifact.title ?? draft?.subject ?? "Email draft"
        ArtifactCardShell(
            icon: AnyView(
                ConnectionLogo(slug: artifact.emailProvider)
            ),
            title: title
        ) {
            if let draft {
                VStack(alignment: .leading, spacing: 4) {
                    if !draft.to.isEmpty {
                        Text("To: \(draft.to.joined(separator: ", "))")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(draft.body)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }
}

/// Calendar invite preview: title + formatted date/time range,
/// attendees, location, and an "Add to Google Calendar" button when
/// the agent supplied a URL (typically a `calendar.google.com/event`
/// or `addeventatc` link).
private struct CalendarArtifactCard: View {
    let artifact: TodoArtifact
    @Environment(\.openURL) private var openURL

    var body: some View {
        let event = artifact.calendarEvent
        let title = event?.title ?? artifact.title ?? "Calendar event"
        ArtifactCardShell(
            icon: AnyView(
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            ),
            title: title
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let when = event.flatMap({ Self.formatRange($0.start, $0.end) }) {
                    Label(when, systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if let location = event?.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let attendees = event?.attendees, !attendees.isEmpty {
                    Label(attendees.joined(separator: ", "),
                          systemImage: "person.2.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let url = event?.url {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Open in Calendar")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color.blue)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Formats a start/end pair in the same style the rest of the detail
    /// view uses: short time on its own when both are missing, a single
    /// date+time when only `start` is known, and a compact range when
    /// both are present (collapsing the date side when start/end share
    /// the same day).
    private static func formatRange(_ start: Date?, _ end: Date?) -> String? {
        guard let start else { return nil }
        let startStr = start.formatted(date: .abbreviated, time: .shortened)
        guard let end else { return startStr }
        let cal = Calendar.current
        if cal.isDate(start, inSameDayAs: end) {
            let endTime = end.formatted(date: .omitted, time: .shortened)
            return "\(startStr) – \(endTime)"
        }
        let endStr = end.formatted(date: .abbreviated, time: .shortened)
        return "\(startStr) → \(endStr)"
    }
}

/// Plain-text deliverable (e.g. a generated summary or snippet). Kept
/// readable rather than scrollable; the text view selects so the user
/// can copy it out.
private struct TextArtifactCard: View {
    let artifact: TodoArtifact

    var body: some View {
        let body = artifact.text ?? ""
        ArtifactCardShell(
            icon: AnyView(
                Image(systemName: "text.alignleft")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            ),
            title: artifact.title ?? "Result"
        ) {
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
