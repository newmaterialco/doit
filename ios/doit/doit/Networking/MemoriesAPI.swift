import Foundation
import Supabase

@MainActor
enum MemoriesAPI {
    static func list() async throws -> [AgentMemory] {
        try await Supa.client
            .from("memories")
            .select()
            .neq("memory_status", value: MemoryLifecycleStatus.deleted.rawValue)
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    static func get(_ id: UUID) async throws -> AgentMemory? {
        let rows: [AgentMemory] = try await Supa.client
            .from("memories")
            .select()
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
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
            target: target.rawValue,
            symbol_name: MemorySymbol.infer(title: title, body: body)
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
            let memory_status: String
            let sync_status: String
            let hermes_fingerprint: String?
            let sync_error: String?
            let symbol_name: String
        }

        _ = try await Supa.client
            .from("memories")
            .update(
                Patch(
                    title: memory.title,
                    body: memory.body,
                    category: memory.category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    target: memory.effectiveTarget.rawValue,
                    memory_status: MemoryLifecycleStatus.active.rawValue,
                    sync_status: MemorySyncStatus.pending.rawValue,
                    hermes_fingerprint: nil,
                    sync_error: nil,
                    symbol_name: MemorySymbol.infer(title: memory.title, body: memory.body)
                )
            )
            .eq("id", value: memory.id)
            .execute()
    }

    static func approve(_ id: UUID) async throws {
        guard let memory = try await get(id) else { return }
        let symbol = memory.symbol_name ?? MemorySymbol.infer(title: memory.title, body: memory.body)
        try await patchLifecycle(
            id,
            status: .active,
            syncStatus: .pending,
            clearFingerprint: true,
            symbolName: symbol
        )
    }

    static func reject(_ id: UUID) async throws {
        try await patchLifecycle(
            id,
            status: .rejected,
            syncStatus: .pending,
            clearFingerprint: true
        )
    }

    static func delete(_ id: UUID) async throws {
        try await patchLifecycle(
            id,
            status: .deleted,
            syncStatus: .pending,
            clearFingerprint: true
        )
    }

    private static func patchLifecycle(
        _ id: UUID,
        status: MemoryLifecycleStatus,
        syncStatus: MemorySyncStatus,
        clearFingerprint: Bool,
        symbolName: String? = nil
    ) async throws {
        struct Patch: Encodable {
            let memory_status: String
            let sync_status: String
            let hermes_fingerprint: String?
            let reviewed_at: Date
            let symbol_name: String?
        }

        _ = try await Supa.client
            .from("memories")
            .update(
                Patch(
                    memory_status: status.rawValue,
                    sync_status: syncStatus.rawValue,
                    hermes_fingerprint: clearFingerprint ? nil : nil,
                    reviewed_at: Date(),
                    symbol_name: symbolName
                )
            )
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
