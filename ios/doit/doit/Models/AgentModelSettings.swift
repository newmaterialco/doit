import Foundation

struct AgentModelCatalogResponse: Codable, Sendable {
    let catalog: [AgentModelProviderOption]
    let setting: AgentModelSetting?
}

struct AgentModelProviderOption: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let models: [AgentModelOption]
}

struct AgentModelOption: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let label: String
    let description: String
}

struct AgentModelSetting: Codable, Hashable, Sendable {
    let user_id: UUID
    var provider: String
    var model: String
    var apply_status: AgentModelApplyStatus
    var apply_error: String?
    var last_applied_at: String?
    var updated_at: String
}

enum AgentModelApplyStatus: String, Codable, Sendable {
    case pending
    case applied
    case failed

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .applied: return "Applied"
        case .failed: return "Failed"
        }
    }
}
