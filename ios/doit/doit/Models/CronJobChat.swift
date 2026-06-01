import Foundation

struct CronJobMessage: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let cron_job_id: UUID
    let user_id: UUID
    let body: String
    let consumed_at: Date?
    let created_at: Date
}

struct NewCronJobMessage: Encodable, Sendable {
    let cron_job_id: UUID
    let user_id: UUID
    let body: String
}

struct CronJobInteraction: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let cron_job_id: UUID
    let user_id: UUID
    let hermes_run_id: String?
    let kind: InteractionKind
    var status: InteractionStatus
    let prompt: String
    let payload: JSONValue?
    var response: JSONValue?
    let created_at: Date
    let updated_at: Date
    var responded_at: Date?

    var summary: String? {
        payload?.objectValue?["summary"]?.stringValue
    }

    var isConfigurationPhase: Bool {
        (payload?.objectValue?["phase"]?.stringValue ?? "") == "configure"
    }

    var content: JSONValue? {
        payload?.objectValue?["content"]
    }

    var allowsFreeform: Bool {
        payload?.objectValue?["allow_freeform"]?.boolValue ?? false
    }

    var freeformPlaceholder: String? {
        payload?.objectValue?["freeform_placeholder"]?.stringValue
    }

    var options: [InteractionOption] {
        guard let raw = payload?.objectValue?["options"]?.arrayValue else { return [] }
        return raw.compactMap { value in
            guard let obj = value.objectValue else { return nil }
            guard let id = obj["id"]?.stringValue,
                  let label = obj["label"]?.stringValue else { return nil }
            let style = obj["style"]?.stringValue.flatMap(InteractionStyle.init(rawValue:))
            return InteractionOption(id: id, label: label, style: style)
        }
    }

    var respondedOptionID: String? {
        response?.objectValue?["option_id"]?.stringValue
    }

    var respondedText: String? {
        let raw = response?.objectValue?["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    var respondedBubbleText: String? {
        if let id = respondedOptionID,
           let label = options.first(where: { $0.id == id })?.label {
            if let extra = respondedText {
                return "\(label) — \(extra)"
            }
            return label
        }
        return respondedText
    }

    var emailDraft: (subject: String, body: String, to: [String])? {
        guard let obj = content?.objectValue else { return nil }
        guard let subject = obj["subject"]?.stringValue,
              let body = obj["body"]?.stringValue else { return nil }
        let to = obj["to"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        return (subject: subject, body: body, to: to)
    }
}

enum CronInteractionPhase {
    case configure

    var nextState: CronJobState {
        .configuring
    }
}

struct CronJobFieldsPatch: Encodable, Sendable {
    let state: String?
    let enabled: Bool?
    let name: String?
    let prompt: String?
    let schedule: String?
    let schedule_display: String?

    init(
        state: CronJobState? = nil,
        enabled: Bool? = nil,
        name: String? = nil,
        prompt: String? = nil,
        schedule: String? = nil,
        schedule_display: String? = nil
    ) {
        self.state = state?.rawValue
        self.enabled = enabled
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.schedule_display = schedule_display
    }
}

struct CronInteractionResponsePatch: Encodable, Sendable {
    let status: String
    let response: InteractionResponse
}
