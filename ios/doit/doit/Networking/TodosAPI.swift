import Foundation
import Supabase

@MainActor
enum TodosAPI {
    static func list() async throws -> [Todo] {
        try await Supa.client
            .from("todos")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    static func create(title: String, detail: String?, userID: UUID) async throws -> Todo {
        // New todos enter `preparing` so the runner can rephrase the title,
        // pick a likely connection icon, and ask for clarification before the
        // user is ever asked to tap "Do it". The raw input is kept verbatim
        // on `original_title` so we don't lose what the user actually typed.
        let row = NewTodo(
            user_id: userID,
            title: title,
            detail: (detail?.isEmpty ?? true) ? nil : detail,
            status: .preparing,
            original_title: title
        )
        let result: [Todo] = try await Supa.client
            .from("todos")
            .insert(row)
            .select()
            .execute()
            .value
        guard let todo = result.first else { throw TodosAPIError.empty }
        return todo
    }

    static func setStatus(_ id: UUID, _ status: TodoStatus) async throws {
        struct Patch: Encodable { let status: String }
        _ = try await Supa.client
            .from("todos")
            .update(Patch(status: status.rawValue))
            .eq("id", value: id)
            .execute()
    }

    static func update(_ id: UUID, title: String, detail: String?) async throws {
        struct Patch: Encodable { let title: String; let detail: String? }
        _ = try await Supa.client
            .from("todos")
            .update(Patch(title: title, detail: (detail?.isEmpty ?? true) ? nil : detail))
            .eq("id", value: id)
            .execute()
    }

    static func delete(_ id: UUID) async throws {
        _ = try await Supa.client
            .from("todos")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    static func steps(for todoID: UUID) async throws -> [TodoStep] {
        try await Supa.client
            .from("todo_steps")
            .select()
            .eq("todo_id", value: todoID)
            .order("ts", ascending: true)
            .execute()
            .value
    }

    // MARK: - Interactions

    static func openInteraction(for todoID: UUID) async throws -> TodoInteraction? {
        let rows: [TodoInteraction] = try await Supa.client
            .from("todo_interactions")
            .select()
            .eq("todo_id", value: todoID)
            .eq("status", value: InteractionStatus.open.rawValue)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Batched fetch for the open interactions of a set of todos. Used by
    /// the list to render the "needs your input" card inline without one
    /// network round-trip per row. Returns a dictionary keyed by todo id;
    /// missing keys mean no open interaction.
    static func openInteractions(for todoIDs: [UUID]) async throws -> [UUID: TodoInteraction] {
        guard !todoIDs.isEmpty else { return [:] }
        let rows: [TodoInteraction] = try await Supa.client
            .from("todo_interactions")
            .select()
            .in("todo_id", values: todoIDs)
            .eq("status", value: InteractionStatus.open.rawValue)
            .order("created_at", ascending: false)
            .execute()
            .value
        var byTodo: [UUID: TodoInteraction] = [:]
        for row in rows where byTodo[row.todo_id] == nil {
            byTodo[row.todo_id] = row
        }
        return byTodo
    }

    /// Submit a user response and re-queue the todo so the runner can resume.
    /// We update the interaction first; the runner reads the response off the
    /// row when it next claims the todo.
    ///
    /// The `phase` controls where the todo lands after a non-cancel response:
    ///   - `.prepare` -> the todo goes back to `preparing` so the runner can
    ///     re-run the preparation pass with the user's answer woven in.
    ///   - `.execute` (default) -> the todo goes to `requested` so the
    ///     execution runner picks it up. This matches the legacy behavior
    ///     for any interactions opened during execution.
    static func respond(
        to interactionID: UUID,
        todoID: UUID,
        optionID: String?,
        text: String?,
        phase: InteractionPhase = .execute
    ) async throws {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = InteractionResponsePatch(
            status: InteractionStatus.responded.rawValue,
            response: InteractionResponse(
                option_id: optionID,
                text: (trimmed?.isEmpty ?? true) ? nil : trimmed
            )
        )
        _ = try await Supa.client
            .from("todo_interactions")
            .update(payload)
            .eq("id", value: interactionID)
            .execute()

        if optionID?.lowercased() == "cancel" {
            try await setStatus(todoID, .cancelled)
        } else {
            try await setStatus(todoID, phase.nextStatus)
        }
    }
}

/// Which phase of the agent loop a `todo_interactions` row belongs to.
/// Stored on the interaction's `payload.phase`; controls how the iOS app
/// re-queues the todo after the user replies.
enum InteractionPhase {
    case prepare
    case execute

    var nextStatus: TodoStatus {
        switch self {
        case .prepare: return .preparing
        case .execute: return .requested
        }
    }
}

enum TodosAPIError: Error {
    case empty
}
