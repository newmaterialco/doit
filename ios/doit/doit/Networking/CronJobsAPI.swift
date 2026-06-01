import Foundation
import Supabase

@MainActor
enum CronJobsAPI {
    static func list() async throws -> [CronJob] {
        try await Supa.client
            .from("cron_jobs")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    static func fetch(_ id: UUID) async throws -> CronJob {
        let rows: [CronJob] = try await Supa.client
            .from("cron_jobs")
            .select()
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        guard let job = rows.first else { throw CronJobsAPIError.notFound }
        return job
    }

    static func setState(_ id: UUID, _ state: CronJobState) async throws {
        try await Supa.client
            .from("cron_jobs")
            .update(CronJobPatch(state: state))
            .eq("id", value: id)
            .execute()
    }

    static func setEnabled(_ id: UUID, _ enabled: Bool) async throws {
        try await Supa.client
            .from("cron_jobs")
            .update(CronJobPatch(enabled: enabled))
            .eq("id", value: id)
            .execute()
    }

    static func delete(_ id: UUID) async throws {
        _ = try await Supa.client
            .from("cron_jobs")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    static func messages(for jobID: UUID) async throws -> [CronJobMessage] {
        try await Supa.client
            .from("cron_job_messages")
            .select()
            .eq("cron_job_id", value: jobID)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    static func interactions(for jobID: UUID) async throws -> [CronJobInteraction] {
        try await Supa.client
            .from("cron_job_interactions")
            .select()
            .eq("cron_job_id", value: jobID)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    @discardableResult
    static func sendMessage(
        jobID: UUID,
        userID: UUID,
        body: String
    ) async throws -> CronJobMessage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CronJobsAPIError.empty }
        let row = NewCronJobMessage(cron_job_id: jobID, user_id: userID, body: trimmed)
        let inserted: [CronJobMessage] = try await Supa.client
            .from("cron_job_messages")
            .insert(row)
            .select()
            .execute()
            .value
        guard let message = inserted.first else { throw CronJobsAPIError.empty }
        try await reconfigure(jobID)
        return message
    }

    static func respond(
        to interactionID: UUID,
        jobID: UUID,
        optionID: String?,
        text: String?
    ) async throws {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = CronInteractionResponsePatch(
            status: InteractionStatus.responded.rawValue,
            response: InteractionResponse(
                option_id: optionID,
                text: (trimmed?.isEmpty ?? true) ? nil : trimmed
            )
        )
        _ = try await Supa.client
            .from("cron_job_interactions")
            .update(payload)
            .eq("id", value: interactionID)
            .execute()

        if optionID?.lowercased() == "cancel" {
            try await setState(jobID, .paused)
            try await setEnabled(jobID, false)
        } else {
            try await reconfigure(jobID)
        }
    }

    private static func reconfigure(_ jobID: UUID) async throws {
        try await Supa.client
            .from("cron_jobs")
            .update(CronJobFieldsPatch(state: .configuring))
            .eq("id", value: jobID)
            .execute()
    }
}

enum CronJobsAPIError: Error {
    case empty
    case notFound
}
