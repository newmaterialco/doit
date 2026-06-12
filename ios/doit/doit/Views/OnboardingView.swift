import SwiftUI

/// Post-signup gate: invite code entry -> "creating your agent" progress ->
/// done (RootView swaps to the task list when `OnboardingModel.isReady`
/// flips). Failure shows a friendly retry.
struct OnboardingView: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(AuthModel.self) private var auth

    @State private var code = ""
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("doit_Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 110)
                .accessibilityLabel("doit")
                .padding(.bottom, 36)

            switch onboarding.phase {
            case .checking:
                ProgressView()
            case .inviteEntry:
                inviteEntry
            case .creating:
                creating
            case .failed(let message):
                failed(message)
            case .ready:
                // RootView swaps to TodoListView; brief frame at most.
                ProgressView()
            }

            Spacer()
            Button("Sign out") {
                Task { await auth.signOut() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .animation(.default, value: onboarding.phase)
    }

    // MARK: - Invite code entry

    private var inviteEntry: some View {
        VStack(spacing: 16) {
            Text("Enter your invite code")
                .font(.title2.weight(.semibold))
            Text("doit is invite-only while we grow. Paste the code you received to create your agent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Invite code", text: $code)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($codeFieldFocused)
                .submitLabel(.go)
                .onSubmit { submit() }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemBackground))
                )

            if let error = onboarding.inviteError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                if onboarding.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(onboarding.isBusy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { codeFieldFocused = true }
    }

    private func submit() {
        guard !onboarding.isBusy else { return }
        Task { await onboarding.redeem(code: code) }
    }

    // MARK: - Creating

    private var creating: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Creating your agent…")
                .font(.title3.weight(.semibold))
            Text("We're setting up your personal assistant. This usually takes under a minute — hang tight.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Failed

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Setup hit a snag")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await onboarding.retry() }
            } label: {
                if onboarding.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Try again")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(onboarding.isBusy)
        }
    }
}
