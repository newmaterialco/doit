import Foundation

enum CronJobState: String, Codable, Sendable, CaseIterable {
    case configuring
    case scheduled
    case paused
    case running
    case completed
    case needs_input

    var label: String {
        switch self {
        case .configuring: return "Setting up…"
        case .scheduled: return "Scheduled"
        case .paused: return "Paused"
        case .running: return "Running"
        case .completed: return "Completed"
        case .needs_input: return "Needs input"
        }
    }

    var isActive: Bool {
        self == .running || self == .configuring
    }
}

struct CronJob: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let user_id: UUID
    var name: String
    var prompt: String
    var schedule: String
    var schedule_display: String?
    var connection_slug: String?
    var state: CronJobState
    var enabled: Bool
    var next_run_at: Date?
    var last_run_at: Date?
    var last_status: String?
    var original_prompt: String?
    var configuration_summary: String?
    /// IANA timezone the job's wall-clock cron expression is evaluated in
    /// (e.g. `America/Los_Angeles`). `nil` means legacy UTC evaluation.
    var timezone: String?
    let created_at: Date
    let updated_at: Date

    /// Short pill label for cards and the detail header.
    var schedulePillText: String {
        SchedulePillFormatter.format(
            schedule: schedule,
            display: schedule_display,
            timezone: timezone
        )
    }

    /// Human-readable schedule line for list cards.
    var scheduleLabel: String {
        schedulePillText
    }

    /// Next run formatted for display.
    var nextRunLabel: String? {
        guard let next = next_run_at else { return nil }
        if next.timeIntervalSinceNow < 60 {
            return "Running soon"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: next, relativeTo: Date())
    }
}

struct CronJobPatch: Encodable, Sendable {
    let state: String?
    let enabled: Bool?

    init(state: CronJobState? = nil, enabled: Bool? = nil) {
        self.state = state?.rawValue
        self.enabled = enabled
    }
}
