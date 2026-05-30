import Foundation
import Supabase

@MainActor
enum MemoriesAPI {
    static func list() async throws -> [AgentMemory] {
        try await Supa.client
            .from("memories")
            .select()
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    static func create(
        title: String,
        body: String,
        category: String?,
        target: MemoryTarget,
        userID: UUID
    ) async throws -> AgentMemory {
        let row = NewAgentMemory(
            user_id: userID,
            title: title,
            body: body,
            category: category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            target: target.rawValue
        )
        let result: [AgentMemory] = try await Supa.client
            .from("memories")
            .insert(row)
            .select()
            .execute()
            .value
        guard let memory = result.first else { throw MemoriesAPIError.empty }
        return memory
    }

    /// Updates a user-authored memory. Any edit re-queues the row for sync
    /// into the matching Hermes file before the next todo run.
    static func update(_ memory: AgentMemory) async throws {
        struct Patch: Encodable {
            let title: String
            let body: String
            let category: String?
            let target: String
            let sync_status: String
            let hermes_fingerprint: String?
            let sync_error: String?
        }

        _ = try await Supa.client
            .from("memories")
            .update(
                Patch(
                    title: memory.title,
                    body: memory.body,
                    category: memory.category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    target: memory.effectiveTarget.rawValue,
                    sync_status: MemorySyncStatus.pending.rawValue,
                    hermes_fingerprint: nil,
                    sync_error: nil
                )
            )
            .eq("id", value: memory.id)
            .execute()
    }

    static func delete(_ id: UUID) async throws {
        _ = try await Supa.client
            .from("memories")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

enum MemoriesAPIError: Error {
    case empty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
