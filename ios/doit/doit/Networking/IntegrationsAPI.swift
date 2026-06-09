import Foundation
import Supabase

struct Toolkit: Codable, Identifiable, Hashable, Sendable {
    var id: String { slug }
    let slug: String
    let name: String
    let description: String
    let auth_type: String?
    let connectable: Bool?
    let connected: Bool
    let connection_id: String?
    let status: String?
    let account_email: String?

    var isConnectable: Bool { connectable ?? true }
    var usesApiKey: Bool { auth_type == "api_key" }
}

struct ConnectResult: Codable, Sendable {
    let redirect_url: String?
    let connection_id: String?
    let connected: Bool?
}

private struct IntegrationsErrorBody: Codable {
    let error: String?
    let detail: String?
}

@MainActor
enum IntegrationsAPI {
    private(set) static var cachedToolkits: [Toolkit]?

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    static func userFacingError(_ error: Error) -> String {
        if let fnError = error as? FunctionsError,
           case .httpError(_, let data) = fnError,
           let body = try? JSONDecoder().decode(IntegrationsErrorBody.self, from: data) {
            if body.error == "invalid_api_key" {
                return body.detail
                    ?? "Hunter rejected this API key. Copy it again from hunter.io → API."
            }
            if let detail = body.detail, !detail.isEmpty {
                return detail
            }
        }

        let description = error.localizedDescription
        if description.contains("invalid_api_key")
            || description.contains("Credentials validation failed") {
            return "Hunter rejected this API key. Copy it again from hunter.io → API (no extra spaces)."
        }
        return description
    }

    static func list() async throws -> [Toolkit] {
        struct Body: Codable { let action: String }
        struct Resp: Codable { let toolkits: [Toolkit] }
        let requestID = UUID().uuidString.prefix(8)
        print("[integrations][\(requestID)] list start")
        let resp: Resp = try await Supa.client.functions
            .invoke("integrations", options: .init(body: Body(action: "list")))
        cachedToolkits = resp.toolkits
        let connected = resp.toolkits
            .filter(\.connected)
            .map { "\($0.slug)=\($0.connection_id ?? "nil")" }
            .joined(separator: ", ")
        print("[integrations][\(requestID)] list ok connected=[\(connected)]")
        return resp.toolkits
    }

    static func connect(toolkit: String, apiKey: String? = nil) async throws -> ConnectResult {
        struct Body: Codable {
            let action: String
            let toolkit: String
            let api_key: String?
        }
        return try await Supa.client.functions
            .invoke(
                "integrations",
                options: .init(body: Body(action: "connect", toolkit: toolkit, api_key: apiKey))
            )
    }

    static func disconnect(connectionID: String, toolkit: String? = nil) async throws {
        struct Body: Codable {
            let action: String
            let connection_id: String
            let toolkit: String?
        }
        struct Resp: Codable {
            let ok: Bool
            let deleted: Int?
            let already_disconnected: Bool?
        }
        let requestID = UUID().uuidString.prefix(8)
        print("[integrations][\(requestID)] disconnect start toolkit=\(toolkit ?? "nil") connection=\(connectionID)")
        let resp: Resp = try await Supa.client.functions
            .invoke(
                "integrations",
                options: .init(
                    body: Body(
                        action: "disconnect",
                        connection_id: connectionID,
                        toolkit: toolkit
                    )
                )
            )
        print(
            "[integrations][\(requestID)] disconnect ok deleted=\(resp.deleted ?? -1) alreadyDisconnected=\(resp.already_disconnected ?? false)"
        )
    }
}
