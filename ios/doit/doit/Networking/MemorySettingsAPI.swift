import Foundation
import Supabase

@MainActor
enum MemorySettingsAPI {
    static func get(userID: UUID) async throws -> MemorySettings {
        let rows: [MemorySettings] = try await Supa.client
            .from("memory_settings")
            .select()
            .eq("user_id", value: userID)
            .limit(1)
            .execute()
            .value
        if let row = rows.first {
            return row
        }
        return try await upsert(
            userID: userID,
            automaticSuggestionsEnabled: true,
            customInstructions: nil
        )
    }

    static func upsert(
        userID: UUID,
        automaticSuggestionsEnabled: Bool,
        customInstructions: String?
    ) async throws -> MemorySettings {
        struct Row: Encodable {
            let user_id: UUID
            let automatic_suggestions_enabled: Bool
            let custom_instructions: String?
        }

        let rows: [MemorySettings] = try await Supa.client
            .from("memory_settings")
            .upsert(
                Row(
                    user_id: userID,
                    automatic_suggestions_enabled: automaticSuggestionsEnabled,
                    custom_instructions: customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ),
                onConflict: "user_id"
            )
            .select()
            .execute()
            .value
        guard let row = rows.first else { throw MemorySettingsAPIError.empty }
        return row
    }
}

enum MemorySettingsAPIError: Error {
    case empty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

