import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AuthModel.self) private var auth
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("doit_Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 140)
                .accessibilityLabel("doit")
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task { await handle(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .font(.system(size: 13, weight: .semibold))
            .frame(height: 58)
            .clipShape(Capsule())
            .padding(.horizontal, 24)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer().frame(height: 12)
        }
        .background(AppSemanticColors.screenBackground.ignoresSafeArea())
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        do {
            switch result {
            case .success(let authResult):
                guard let cred = authResult.credential as? ASAuthorizationAppleIDCredential else {
                    errorMessage = "Apple didn't return the expected credential."
                    return
                }
                try await auth.completeSignInWithApple(cred)
                errorMessage = nil
            case .failure(let err):
                if (err as NSError).code == ASAuthorizationError.canceled.rawValue {
                    errorMessage = nil
                } else {
                    errorMessage = "Sign in failed: \(err.localizedDescription)"
                }
            }
        } catch {
            errorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }
}
