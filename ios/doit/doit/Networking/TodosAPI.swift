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

    // MARK: - Artifacts

    /// Lists every artifact the agent has produced for a todo, oldest
    /// first. The runner upserts on `(todo_id, artifact_key)` so a given
    /// `artifact_key` only appears once and re-emitting it from a later
    /// run replaces the row in place rather than appending a new one.
    static func artifacts(for todoID: UUID) async throws -> [TodoArtifact] {
        try await Supa.client
            .from("todo_artifacts")
            .select()
            .eq("todo_id", value: todoID)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Batched artifact fetch for the list view connection icons.
    static func artifacts(for todoIDs: [UUID]) async throws -> [UUID: [TodoArtifact]] {
        guard !todoIDs.isEmpty else { return [:] }
        let rows: [TodoArtifact] = try await Supa.client
            .from("todo_artifacts")
            .select()
            .in("todo_id", values: todoIDs)
            .order("created_at", ascending: true)
            .execute()
            .value
        var byTodo: [UUID: [TodoArtifact]] = [:]
        for row in rows where row.hasContent {
            byTodo[row.todo_id, default: []].append(row)
        }
        return byTodo
    }

    // MARK: - Messages (free-form user chat)

    /// All user-authored chat messages for a todo, oldest first. The
    /// detail view interleaves these with `todo_steps` to render a
    /// conversational timeline.
    static func messages(for todoID: UUID) async throws -> [TodoMessage] {
        try await Supa.client
            .from("todo_messages")
            .select()
            .eq("todo_id", value: todoID)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Insert a free-form chat message and re-queue the todo so the runner
    /// resumes the same Hermes session with this message woven into the
    /// prompt. Returns the persisted row so callers can append it locally
    /// without waiting on a realtime round-trip.
    @discardableResult
    static func sendMessage(
        todoID: UUID,
        userID: UUID,
        body: String
    ) async throws -> TodoMessage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodosAPIError.empty }
        let row = NewTodoMessage(todo_id: todoID, user_id: userID, body: trimmed)
        let inserted: [TodoMessage] = try await Supa.client
            .from("todo_messages")
            .insert(row)
            .select()
            .execute()
            .value
        guard let message = inserted.first else { throw TodosAPIError.empty }
        try await setStatus(todoID, .requested)
        return message
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

    /// Full history of interactions for a single todo, oldest first. The
    /// detail view uses this so closed (responded/cancelled) interactions
    /// stay visible in the chat transcript instead of vanishing the moment
    /// the user answers — which lines the UX up with how every other chat
    /// app on the planet behaves.
    static func interactions(for todoID: UUID) async throws -> [TodoInteraction] {
        let rows: [TodoInteraction] = try await Supa.client
            .from("todo_interactions")
            .select()
            .eq("todo_id", value: todoID)
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows
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
