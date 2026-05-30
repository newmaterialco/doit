import AuthenticationServices
import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class AuthModel {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(userID: UUID)
    }

    var state: State = .loading
    /// Two-letter initials derived from the user's persisted name metadata, when available.
    private(set) var initials: String?
    private var listenerTask: Task<Void, Never>?

    func bootstrap() {
        if listenerTask != nil { return }
        // Pick up any existing session immediately.
        Task {
            let session = try? await Supa.client.auth.session
            self.apply(session: session)
        }
        // Then listen for changes.
        listenerTask = Task { [weak self] in
            for await (_, session) in Supa.client.auth.authStateChanges {
                self?.apply(session: session)
            }
        }
    }

    func signOut() async {
        try? await Supa.client.auth.signOut()
        self.state = .signedOut
        self.initials = nil
    }

    /// Exchange an Apple ID credential's identity token for a Supabase session.
    func completeSignInWithApple(_ credential: ASAuthorizationAppleIDCredential) async throws {
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            throw AuthError.missingIdentityToken
        }
        _ = try await Supa.client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: token)
        )
        // Apple only returns `fullName` on the very first authorization for an
        // Apple ID. Persist it to user metadata so we can render initials later.
        if let name = credential.fullName {
            await persistAppleName(name)
        }
    }

    private func persistAppleName(_ name: PersonNameComponents) async {
        let given = name.givenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let family = name.familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !given.isEmpty || !family.isEmpty else { return }

        var data: [String: AnyJSON] = [:]
        if !given.isEmpty { data["first_name"] = .string(given) }
        if !family.isEmpty { data["last_name"] = .string(family) }

        do {
            let updated = try await Supa.client.auth.update(
                user: UserAttributes(data: data)
            )
            self.initials = Self.computeInitials(from: updated.userMetadata)
        } catch {
            print("[auth] failed to persist apple name: \(error)")
        }
    }

    private func apply(session: Session?) {
        if let s = session {
            self.state = .signedIn(userID: s.user.id)
            self.initials = Self.computeInitials(from: s.user.userMetadata)
        } else {
            self.state = .signedOut
            self.initials = nil
        }
    }

    private static func computeInitials(from metadata: [String: AnyJSON]) -> String? {
        let first = metadata["first_name"]?.stringValue ?? ""
        let last = metadata["last_name"]?.stringValue ?? ""
        let f = first.first.map { String($0).uppercased() } ?? ""
        let l = last.first.map { String($0).uppercased() } ?? ""
        let combined = f + l
        return combined.isEmpty ? nil : combined
    }
}

enum AuthError: Error {
    case missingIdentityToken
}
