import Foundation
import Supabase
import UIKit

@MainActor
enum FeedbackAPI {
    static func submit(
        message: String,
        includeEmail: Bool,
        contactEmail: String? = nil
    ) async throws {
        struct Body: Codable {
            let action: String
            let message: String
            let include_email: Bool
            let contact_email: String?
            let app_version: String?
            let ios_version: String?
            let device_model: String?
        }
        struct Resp: Codable { let ok: Bool }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let versionLabel: String? = {
            switch (appVersion, buildNumber) {
            case let (.some(version), .some(build)):
                return "\(version) (\(build))"
            case let (.some(version), nil):
                return version
            default:
                return nil
            }
        }()

        let body = Body(
            action: "submit",
            message: message,
            include_email: includeEmail,
            contact_email: includeEmail ? contactEmail : nil,
            app_version: versionLabel,
            ios_version: UIDevice.current.systemVersion,
            device_model: UIDevice.current.model
        )
        let _: Resp = try await Supa.client.functions
            .invoke("feedback", options: .init(body: body))
    }
}
