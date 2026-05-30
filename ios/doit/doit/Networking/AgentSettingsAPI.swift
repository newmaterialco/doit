import Foundation
import Supabase

@MainActor
enum AgentSettingsAPI {
    static func getModelSettings() async throws -> AgentModelCatalogResponse {
        struct Body: Codable { let action: String }
        return try await Supa.client.functions
            .invoke("agent-settings", options: .init(body: Body(action: "get")))
    }

    static func updateModelSettings(
        provider: String,
        model: String
    ) async throws -> AgentModelSetting {
        struct Body: Codable {
            let action: String
            let provider: String
            let model: String
        }
        struct Resp: Codable { let setting: AgentModelSetting }

        let body = Body(
            action: "update",
            provider: provider,
            model: model
        )
        let resp: Resp = try await Supa.client.functions
            .invoke("agent-settings", options: .init(body: body))
        return resp.setting
    }
}
