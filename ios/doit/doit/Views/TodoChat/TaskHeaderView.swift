import SwiftUI

/// Shared layout constants for the title column, checkmark gutter, and
/// metadata row inset so the date and downstream cards line up with the
/// task title instead of the leading checkmark circle.
private enum TaskHeaderLayout {
    static let statusIconSize: CGFloat = 28
    static let statusIconSpacing: CGFloat = 12
    static let headerDateFontSize: CGFloat = 15
    static let headerConnectionIconSize: CGFloat = 18
    static let headerMetadataDotSize: CGFloat = 4
    /// Extra space between the compact header row and the task title.
    static let headerToTitleSpacing: CGFloat = 12
    /// Breathing room below the final artifact card before the split handle /
    /// chat panel begins.
    static let artifactsBottomPadding: CGFloat = 18
    static let artifactSeparatorLength: CGFloat = 10
    static let artifactSeparatorThickness: CGFloat = 1
    static let artifactSeparatorSpacing: CGFloat = 5
}

/// Top panel of the split-screen detail view: a compact action row with
/// back, centered created-at time and connection logos, and a more-actions
/// menu, then a status indicator + title + optional agent-status / artifacts below.
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
    /// Live agent activity snapshot driving the animated activity card
    /// at the top of the detail view. `nil` when no run is in flight.
    /// Sourced from `TodoStore.agentActivityByTodoID`.
    let agentActivity: AgentActivity?
    let onBack: () -> Void
    let onDelete: () -> Void
    /// Opens the chat panel — wired from the detail view when the user taps
    /// the live activity card stack under the title.
    let onTapActivity: () -> Void

    @State private var isEmailBatchExpanded = false

    /// Explicit memberwise init so Xcode's incremental compiler can't
    /// keep a stale synthesized signature around when this view's
    /// surface changes — once bit me with "Extra argument 'agentStatus'
    /// in call" after editing the property list. Defaults keep older
    /// call sites and previews terse.
    init(
        todo: Todo,
        artifacts: [TodoArtifact] = [],
        agentStatus: String? = nil,
        agentActivity: AgentActivity? = nil,
        onBack: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onTapActivity: @escaping () -> Void = {}
    ) {
        self.todo = todo
        self.artifacts = artifacts
        self.agentStatus = agentStatus
        self.agentActivity = agentActivity
        self.onBack = onBack
        self.onDelete = onDelete
        self.onTapActivity = onTapActivity
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerActionRow

                taskTitleBlock
                    .padding(.top, TaskHeaderLayout.headerToTitleSpacing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.3), value: agentStatus)
            .animation(.smooth(duration: 0.3), value: agentActivity?.activitySignature)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Back and more menu pinned to the edges; created-at + connection
    /// logos centered evenly between them.
    private var headerActionRow: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 6) {
                Text(humanizedDate(todo.created_at))
                    .font(.system(size: TaskHeaderLayout.headerDateFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Created \(humanizedDate(todo.created_at))")

                if !connectionSlugs.isEmpty {
                    headerMetadataDot
                    connectionLogosRow
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("Delete Task", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
        }
    }

    private var headerMetadataDot: some View {
        Circle()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: TaskHeaderLayout.headerMetadataDotSize, height: TaskHeaderLayout.headerMetadataDotSize)
            .accessibilityHidden(true)
    }

    private var connectionSlugs: [String] {
        TodoArtifact.connectionSlugs(todoSlug: todo.connection_slug, artifacts: artifacts)
    }

    @ViewBuilder
    private var connectionLogosRow: some View {
        ConnectionLogosRow(
            slugs: connectionSlugs,
            iconSize: TaskHeaderLayout.headerConnectionIconSize,
            spacing: 5
        )
    }

    private var shouldShowAgentStatus: Bool {
        guard let status = agentStatus, !status.isEmpty else { return false }
        return agentActivity?.isRunning != true
    }

    /// Show the activity card whenever we have a snapshot, including
    /// settled `completed`/`failed` snapshots — they fade out shortly
    /// after the chat thread renders the final reply, but during the
    /// window the user just navigated in, the card is the cleanest
    /// recap of what just happened. We hide only the never-ran case
    /// (nil) and the `idle` placeholder phase.
    private func shouldShowActivityCard(_ activity: AgentActivity) -> Bool {
        activity.resolvedPhase != .idle
    }

    /// Checkmark and title share one row; activity cards and artifacts span full width below.
    @ViewBuilder
    private var taskTitleBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
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

                    if shouldShowAgentStatus, let status = agentStatus {
                        agentStatusBox(text: status)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let activity = agentActivity, shouldShowActivityCard(activity) {
                Button(action: onTapActivity) {
                    AgentActivityCard(activity: activity, isTaskActive: todo.status.isActive)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(AppSemanticColors.insetPanelBackground)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open chat")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !artifacts.isEmpty {
                artifactsSection()
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
    private func artifactsSection() -> some View {
        let grouped = TodoArtifact.groupedForDisplay(artifacts)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(grouped.primary.enumerated()), id: \.element.id) { index, artifact in
                if index > 0 {
                    artifactSeparator
                }
                TaskArtifactView(artifact: artifact)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !grouped.emailDrafts.isEmpty {
                if !grouped.primary.isEmpty {
                    artifactSeparator
                }
                emailArtifactsSection(emails: grouped.emailDrafts)
            }
        }
        .animation(.smooth(duration: 0.25), value: artifacts.map(\.id))
        .padding(.top, 4)
        .padding(.bottom, TaskHeaderLayout.artifactsBottomPadding)
    }

    private var artifactSeparator: some View {
        Capsule(style: .continuous)
            .fill(Color.secondary.opacity(0.28))
            .frame(
                width: TaskHeaderLayout.artifactSeparatorThickness,
                height: TaskHeaderLayout.artifactSeparatorLength
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, TaskHeaderLayout.artifactSeparatorSpacing)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func emailArtifactsSection(emails: [TodoArtifact]) -> some View {
        if emails.count == 1, let email = emails.first {
            TaskArtifactView(artifact: email)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    ArtifactCardLayout.playTapHaptic()
                    withAnimation(.smooth(duration: 0.25)) {
                        isEmailBatchExpanded.toggle()
                    }
                } label: {
                    emailBatchPill(emails: emails)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isEmailBatchExpanded
                        ? "Hide \(EmailArtifactStatus.batchSummary(for: emails))"
                        : "Show \(EmailArtifactStatus.batchSummary(for: emails))"
                )

                if isEmailBatchExpanded {
                    Group {
                        artifactSeparator
                        ForEach(Array(emails.enumerated()), id: \.element.id) { index, artifact in
                            if index > 0 {
                                artifactSeparator
                            }
                            TaskArtifactView(artifact: artifact)
                        }
                    }
                    .transition(emailBatchExpansionTransition)
                }
            }
        }
    }

    private var emailBatchExpansionTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .offset(y: -4))
        )
    }

    private func emailBatchPill(emails: [TodoArtifact]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ArtifactCardLeadingIcon {
                ConnectionLogo(slug: emails.first?.emailProvider ?? "gmail")
            }

            Text(EmailArtifactStatus.batchSummary(for: emails))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isEmailBatchExpanded ? 180 : 0))
        }
        .padding(ArtifactCardLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
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
        Group {
            if status == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.green)
            } else if status.isActive {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(statusIndicatorAccessibilityLabel)
    }

    private var statusIndicatorAccessibilityLabel: String {
        switch status {
        case .done: return "Task completed"
        case .preparing, .requested, .running: return "Task in progress"
        default: return "Task not completed"
        }
    }
}

// MARK: - Artifact card

/// Compact card the agent uses to surface a final deliverable — a created
/// doc/sheet link, a sent email, a calendar invite, a text result, or a
/// Hermes-generated spoken summary. Dispatches on `artifact.kind` to one
/// of six small renderers; unknown or empty payloads short-circuit to
/// nothing so a malformed row never leaves a blank tile in the header.
struct TaskArtifactView: View {
    let artifact: TodoArtifact

    var body: some View {
        Group {
            switch artifact.kind {
            case .link: LinkArtifactCard(artifact: artifact)
            case .email: EmailArtifactCard(artifact: artifact)
            case .calendar: CalendarArtifactCard(artifact: artifact)
            case .text: TextArtifactCard(artifact: artifact)
            case .audio: AudioArtifactCard(artifact: artifact)
            case .image: ImageArtifactCard(artifact: artifact)
            case .options: OptionsArtifactCard(artifact: artifact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(alignment: .top, spacing: 10) {
                ArtifactCardLeadingIcon { icon }
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
                    .padding(.top, 2)
            }
            content()
        }
        .padding(ArtifactCardLayout.contentPadding)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let onTap {
            Button(action: {
                ArtifactCardLayout.playTapHaptic()
                onTap()
            }) { card }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            card
        }
    }
}

/// Open-in-browser card for `link` artifacts. The leading glyph prefers a
/// bundled connection logo, then a host favicon, then a generic link symbol.
private struct LinkArtifactCard: View {
    let artifact: TodoArtifact
    @Environment(\.openURL) private var openURL

    var body: some View {
        let title = artifact.title ?? artifact.url?.host ?? "Open link"
        let url = artifact.url
        cardBody(title: title, url: url)
            .contentShape(Rectangle())
            .onTapGesture {
                if let url {
                    openLink(url)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(url == nil ? "" : "Open link")
    }

    @ViewBuilder
    private func cardBody(title: String, url: URL?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ArtifactCardLeadingIcon {
                LinkArtifactIcon(provider: artifact.provider, url: artifact.url)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let url {
                Button {
                    openLink(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open link")
            }
        }
        .padding(ArtifactCardLayout.contentPadding)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openLink(_ url: URL) {
        ArtifactCardLayout.playTapHaptic()
        openURL(url)
    }
}

/// Email preview styled like the chat's Gmail draft card: provider logo,
/// subject, status, recipients, and a truncated body with expand.
private struct EmailArtifactCard: View {
    let artifact: TodoArtifact

    var body: some View {
        let draft = artifact.emailDraft
        HStack(alignment: .top, spacing: 10) {
            ArtifactCardLeadingIcon {
                ConnectionLogo(slug: artifact.emailProvider)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(artifact.title ?? draft?.subject ?? artifact.emailFallbackTitle)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(artifact.emailStatusLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                if let draft {
                    if !draft.to.isEmpty {
                        Text("To: \(draft.to.joined(separator: ", "))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }

                    if !draft.body.isEmpty {
                        TruncatableArtifactText(text: draft.body, lineLimit: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ArtifactCardLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
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
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            ),
            title: title
        ) {
            ArtifactTruncatableSection(isTruncatable: isTruncatable(event: event)) { isExpanded in
                VStack(alignment: .leading, spacing: 6) {
                    if let when = event.flatMap({ Self.formatRange($0.start, $0.end) }) {
                        Label(when, systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                    if let location = event?.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                    if let attendees = event?.attendees, !attendees.isEmpty {
                        Label(attendees.joined(separator: ", "),
                              systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                    if let url = event?.url {
                        Button {
                            ArtifactCardLayout.playTapHaptic()
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
    }

    private func isTruncatable(event: TodoArtifact.CalendarEvent?) -> Bool {
        let location = event?.location ?? ""
        let attendees = event?.attendees.joined(separator: ", ") ?? ""
        if location.count > 60 || attendees.count > 60 { return true }
        return (event?.attendees.count ?? 0) > 2
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

/// Plain-text deliverable (e.g. a generated summary or snippet). The
/// header row toggles a grey body panel below; long results start
/// collapsed with a chevron instead of an inline "Show more" link.
private struct TextArtifactCard: View {
    let artifact: TodoArtifact

    @State private var isExpanded = false

    var body: some View {
        let body = artifact.text ?? ""
        let title = artifact.title ?? "Result"
        let hasBody = !body.isEmpty
        let collapsible = hasBody && isTruncatable(body)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard collapsible else { return }
                ArtifactCardLayout.playTapHaptic()
                withAnimation(.smooth(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    ArtifactCardLeadingIcon {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                    }

                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if collapsible {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .padding(ArtifactCardLayout.contentPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!collapsible)
            .accessibilityLabel(title)
            .accessibilityHint(
                collapsible
                    ? (isExpanded ? "Collapse response" : "Expand response")
                    : ""
            )

            if hasBody, !collapsible || isExpanded {
                MarkdownMessageText(text: body, fontSize: 15)
                    .multilineTextAlignment(.leading)
                    .padding(ArtifactCardLayout.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: 18,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                        .fill(Color.primary.opacity(0.04))
                    }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isTruncatable(_ text: String) -> Bool {
        let lineLimit = 4
        let lines = text.components(separatedBy: .newlines)
        if lines.count > lineLimit { return true }
        return text.count > lineLimit * 40
    }
}
