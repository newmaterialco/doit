import Foundation
import Supabase

struct GeneratedSuggestion: Codable, Hashable, Sendable {
    let title: String
    let theme: String
    let connection_slug: String?
}

struct SuggestionsResponse: Codable, Sendable {
    let suggestions: [GeneratedSuggestion]
    let degraded: Bool?
    let error: String?
}

@MainActor
enum SuggestionsAPI {
    static func fetch(
        count: Int = 5,
        excludeTitles: [String] = []
    ) async throws -> SuggestionsResponse {
        try await invoke(functionName: "task-suggestions", count: count, excludeTitles: excludeTitles)
    }

    static func fetchCron(
        count: Int = 5,
        excludeTitles: [String] = []
    ) async throws -> SuggestionsResponse {
        try await invoke(functionName: "cron-suggestions", count: count, excludeTitles: excludeTitles)
    }

    private static func invoke(
        functionName: String,
        count: Int,
        excludeTitles: [String]
    ) async throws -> SuggestionsResponse {
        struct Body: Codable {
            let count: Int
            let exclude_titles: [String]
        }

        return try await Supa.client.functions
            .invoke(
                functionName,
                options: .init(
                    body: Body(
                        count: count,
                        exclude_titles: excludeTitles
                    )
                )
            )
    }
}
