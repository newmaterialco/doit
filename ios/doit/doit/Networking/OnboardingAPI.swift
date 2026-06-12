import Foundation
import Supabase

/// Provisioning row mirrored from `user_provisioning` (self-read RLS).
/// Timestamps stay as raw strings; the onboarding screen never renders them.
struct OnboardingProvisioning: Codable, Equatable {
    let user_id: UUID
    let status: String  // pending | provisioning | ready | failed
    let error: String?
    let created_at: String
    let updated_at: String
}

struct OnboardingStatusResponse: Codable {
    let provisioning: OnboardingProvisioning?
    /// True when a `user_hermes` row exists — the agent is usable even if
    /// the provisioning row lags (e.g. manually-onboarded early users).
    let agent_ready: Bool
}

struct OnboardingRedeemResponse: Codable {
    let ok: Bool
    /// redeemed | retry | already_redeemed | already_provisioned | invalid_code
    let reason: String
    let provisioning: OnboardingProvisioning?
}

/// Typed client for the `onboarding` Edge Function.
@MainActor
enum OnboardingAPI {
    static func status() async throws -> OnboardingStatusResponse {
        struct Body: Codable { let action: String }
        return try await Supa.client.functions
            .invoke("onboarding", options: .init(body: Body(action: "status")))
    }

    static func redeem(code: String) async throws -> OnboardingRedeemResponse {
        struct Body: Codable {
            let action: String
            let code: String
        }
        return try await Supa.client.functions
            .invoke("onboarding", options: .init(body: Body(action: "redeem", code: code)))
    }
}
