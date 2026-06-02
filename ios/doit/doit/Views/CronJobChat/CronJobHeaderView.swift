import SwiftUI

private enum CronJobHeaderLayout {
    static let headerDateFontSize: CGFloat = 15
    static let headerConnectionIconSize: CGFloat = 18
    static let headerMetadataDotSize: CGFloat = 4
    static let headerToTitleSpacing: CGFloat = 12
    static let titleIconSize: CGFloat = 28
    static let titleIconSpacing: CGFloat = 12
}

/// Top panel for the cron job detail split view: centered created-at time
/// and connection logos between back and menu, then schedule icon + title.
struct CronJobHeaderView: View {
    let job: CronJob
    let agentStatus: String?
    let onBack: () -> Void
    let onDelete: () -> Void

    private static let scheduleSymbol =
        "clock.arrow.trianglehead.counterclockwise.rotate.90"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerActionRow

                titleBlock
                    .padding(.top, CronJobHeaderLayout.headerToTitleSpacing)
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
                Text(humanizedDate(job.created_at))
                    .font(.system(size: CronJobHeaderLayout.headerDateFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Created \(humanizedDate(job.created_at))")

                if !connectionSlugs.isEmpty {
                    headerMetadataDot
                    connectionLogosRow
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("Delete schedule", role: .destructive, action: onDelete)
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
            .frame(
                width: CronJobHeaderLayout.headerMetadataDotSize,
                height: CronJobHeaderLayout.headerMetadataDotSize
            )
            .accessibilityHidden(true)
    }

    private var connectionSlugs: [String] {
        guard let slug = job.connection_slug, !slug.isEmpty else { return [] }
        return [slug]
    }

    @ViewBuilder
    private var connectionLogosRow: some View {
        ConnectionLogosRow(
            slugs: connectionSlugs,
            iconSize: CronJobHeaderLayout.headerConnectionIconSize,
            spacing: 5
        )
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: CronJobHeaderLayout.titleIconSpacing) {
            Image(systemName: Self.scheduleSymbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: CronJobHeaderLayout.titleIconSize, height: CronJobHeaderLayout.titleIconSize)
                .symbolEffect(.pulse, isActive: job.state.isActive)

            VStack(alignment: .leading, spacing: 12) {
                Text(job.name)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)

                Text(job.schedulePillText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.35))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.92))
                    )
                    .accessibilityLabel("Schedule: \(job.schedulePillText)")

                if let status = agentStatus, !status.isEmpty {
                    agentStatusBox(text: status)
                } else if let summary = job.configuration_summary,
                          !summary.isEmpty,
                          job.state == .needs_input || job.state == .configuring {
                    agentStatusBox(text: summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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

    private func humanizedDate(_ date: Date) -> String {
        let cal = Calendar.current
        let timeStr = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today at \(timeStr)" }
        if cal.isDateInYesterday(date) { return "Yesterday at \(timeStr)" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
            + " at \(timeStr)"
    }
}
