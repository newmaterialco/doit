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
    private(set) var displayName: String = "You"
    private(set) var avatarURL: URL?
    private(set) var avatarImageData: Data?
    private(set) var joinedAt: Date?
    private(set) var email: String?
    private(set) var phoneNumber: String?
    private var repairedOversizedAvatarMetadata = false
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
        self.displayName = "You"
        self.avatarURL = nil
        self.avatarImageData = nil
        self.joinedAt = nil
        self.email = nil
        self.phoneNumber = nil
        self.repairedOversizedAvatarMetadata = false
    }

    func updateProfile(displayName: String, avatarImageData: Data?) async throws {
        guard case .signedIn(let userID) = state else { throw AuthError.notSignedIn }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "You" : trimmedName
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)

        let data: [String: AnyJSON] = [
            "full_name": .string(name),
            "first_name": .string(parts.first ?? name),
            "last_name": .string(parts.count > 1 ? parts[1] : ""),
            // Never put image bytes in auth metadata. Those fields are copied
            // into JWTs and can make Authorization headers too large to send.
            "avatar_data_url": .null
        ]
        if let avatarImageData {
            try Self.saveLocalAvatar(avatarImageData, userID: userID)
        }

        let updated = try await Supa.client.auth.update(
            user: UserAttributes(data: data)
        )
        _ = try? await Supa.client.auth.refreshSession()
        apply(userMetadata: updated.userMetadata, createdAt: updated.createdAt, userID: userID)
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
            if case .signedIn(let userID) = state {
                apply(userMetadata: updated.userMetadata, createdAt: updated.createdAt, userID: userID)
            }
        } catch {
            print("[auth] failed to persist apple name: \(error)")
        }
    }

    private func apply(session: Session?) {
        if let s = session {
            self.state = .signedIn(userID: s.user.id)
            self.email = s.user.email
            self.phoneNumber = s.user.phone
            apply(userMetadata: s.user.userMetadata, createdAt: s.user.createdAt, userID: s.user.id)
            repairOversizedAvatarMetadataIfNeeded(s.user.userMetadata, userID: s.user.id, createdAt: s.user.createdAt)
        } else {
            self.state = .signedOut
            self.initials = nil
            self.displayName = "You"
            self.avatarURL = nil
            self.avatarImageData = nil
            self.joinedAt = nil
            self.email = nil
            self.phoneNumber = nil
            self.repairedOversizedAvatarMetadata = false
        }
    }

    private func apply(userMetadata: [String: AnyJSON], createdAt: Date, userID: UUID) {
        self.initials = Self.computeInitials(from: userMetadata)
        self.displayName = Self.computeDisplayName(from: userMetadata)
        self.avatarURL = Self.computeAvatarURL(from: userMetadata)
        self.avatarImageData = Self.loadLocalAvatar(userID: userID)
        self.joinedAt = createdAt
    }

    private func repairOversizedAvatarMetadataIfNeeded(
        _ metadata: [String: AnyJSON],
        userID: UUID,
        createdAt: Date
    ) {
        guard !repairedOversizedAvatarMetadata else { return }
        guard let dataURL = metadata["avatar_data_url"]?.stringValue, dataURL.hasPrefix("data:") else { return }

        repairedOversizedAvatarMetadata = true
        if let imageData = Self.decodeDataURL(dataURL) {
            try? Self.saveLocalAvatar(imageData, userID: userID)
            self.avatarImageData = imageData
        }

        Task {
            do {
                let updated = try await Supa.client.auth.update(
                    user: UserAttributes(data: ["avatar_data_url": .null])
                )
                _ = try? await Supa.client.auth.refreshSession()
                apply(userMetadata: updated.userMetadata, createdAt: createdAt, userID: userID)
            } catch {
                print("[auth] failed to clear oversized avatar metadata: \(error)")
            }
        }
    }

    private static func computeInitials(from metadata: [String: AnyJSON]) -> String? {
        let displayName = computeDisplayName(from: metadata)
        let parts = displayName.split(separator: " ")
        let f = parts.first?.first.map { String($0).uppercased() } ?? ""
        let l = parts.dropFirst().first?.first.map { String($0).uppercased() } ?? ""
        let combined = f + l
        return combined.isEmpty ? nil : combined
    }

    private static func computeDisplayName(from metadata: [String: AnyJSON]) -> String {
        let fullName = metadata["full_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fullName.isEmpty { return fullName }

        let first = metadata["first_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = metadata["last_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let joined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? "You" : joined
    }

    private static func computeAvatarURL(from metadata: [String: AnyJSON]) -> URL? {
        let rawURL = metadata["avatar_url"]?.stringValue ?? metadata["picture"]?.stringValue ?? ""
        guard !rawURL.hasPrefix("data:") else { return nil }
        return URL(string: rawURL)
    }

    private static func decodeDataURL(_ dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",")
        else { return nil }

        let encoded = String(dataURL[dataURL.index(after: commaIndex)...])
        return Data(base64Encoded: encoded)
    }

    private static func localAvatarURL(userID: UUID) throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("ProfileAvatars", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("\(userID.uuidString.lowercased()).jpg")
    }

    private static func saveLocalAvatar(_ data: Data, userID: UUID) throws {
        try data.write(to: localAvatarURL(userID: userID), options: [.atomic])
    }

    private static func loadLocalAvatar(userID: UUID) -> Data? {
        guard let url = try? localAvatarURL(userID: userID) else { return nil }
        return try? Data(contentsOf: url)
    }
}

enum AuthError: Error {
    case missingIdentityToken
    case notSignedIn
}
