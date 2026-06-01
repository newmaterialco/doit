import SwiftUI

/// Top panel for the cron job detail split view: back + menu, schedule
/// pill under the title, optional configuration status card.
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

                    Text(job.state.label)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

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

                HStack(alignment: .center, spacing: 8) {
                    Text(humanizedDate(job.created_at))
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let slug = job.connection_slug, !slug.isEmpty {
                        ConnectionLogo(slug: slug)
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(.leading, 40)
                .padding(.top, 12)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: Self.scheduleSymbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
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
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
