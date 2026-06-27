import SwiftUI
import UIKit

/// Post-signup gate: invite code entry -> "creating your agent" progress ->
/// done (RootView swaps to the task list when `OnboardingModel.isReady`
/// flips). Failure shows a friendly retry.
struct OnboardingView: View {
    private static let waitlistURL = AppConfig.waitlistURL

    @Environment(OnboardingModel.self) private var onboarding
    @Environment(AuthModel.self) private var auth
    @Environment(AppSetupModeStore.self) private var setupMode

    @State private var code = ""
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            switch onboarding.phase {
            case .checking:
                ProgressView()
            case .inviteEntry:
                inviteEntry
            case .creating:
                creating
            case .failed(let message):
                failed(message)
            case .byoPairing(let prepared, let status):
                byoPairing(prepared, status: status)
            case .ready:
                // RootView swaps to TodoListView; brief frame at most.
                ProgressView()
            }

            Spacer()
            Button(setupMode.isBYO ? "Back to Options" : "Sign out") {
                Task { await leaveOnboarding() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .background(AppSemanticColors.screenBackground.ignoresSafeArea())
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

            HStack(spacing: 0) {
                Text("No code? Join the waitlist ")
                    .foregroundStyle(.secondary)
                Link("here", destination: Self.waitlistURL)
            }
            .font(.footnote)

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

    private func leaveOnboarding() async {
        await auth.signOut()
        onboarding.reset()
        if setupMode.isBYO {
            setupMode.reset()
        }
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

    // MARK: - BYO Connector

    private func byoPairing(
        _ prepared: BYOConnectorPrepareResponse,
        status: BYOConnectorStatus?
    ) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pair your Hermes connector")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Doit uses your Hermes setup as-is. Your keys, connections, memory stay on your machine.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                PairingStep(number: 1, text: "Copy the installer command.")
                PairingStep(number: 2, text: "Run it on the VPS that can reach Hermes.")
                PairingStep(number: 3, text: "Leave the service running while you use Doit.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("Pairing code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        if status?.status == "online" {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(status?.status == "online" ? "Connector found" : "Waiting for connector...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(prepared.pairing_code)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Divider()
                Text("Install connector on your VPS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("This clones Doit, creates a Python venv, and starts doit-connector.service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prepared.install_command)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy installer command") {
                    UIPasteboard.general.string = prepared.install_command
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(16)
            .pairingCardStyle()

            VStack(alignment: .leading, spacing: 10) {
                Text("Need help?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("If Hermes has terminal access, paste this prompt into Hermes and ask it to run the installer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Hermes prompt") {
                    UIPasteboard.general.string = hermesHelpPrompt(prepared)
                }
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .pairingCardStyle()

            capabilitySummary(status?.capabilities)
        }
    }

    private func hermesHelpPrompt(_ prepared: BYOConnectorPrepareResponse) -> String {
        """
        I want to connect my existing Hermes setup to the Doit iOS app using BYO connector mode.

        Please help me run this Doit connector installer. It should run on the machine that can reach my Hermes HTTP API, usually the same VPS/server where Hermes is already running.

        Installer command:
        \(prepared.install_command)

        Please check:
        1. Whether Hermes is running and what host/port I should use for DOIT_HERMES_URL.
        2. Whether I need a Hermes API key and should set DOIT_HERMES_API_KEY before running it.
        3. Whether curl, git, python3, and systemd are available on this machine.
        4. The final command I should paste into my terminal.
        5. Whether doit-connector.service starts successfully after install.
        """
    }

    @ViewBuilder
    private func capabilitySummary(_ capabilities: [String: String]?) -> some View {
        if let capabilities, !capabilities.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reported by your Hermes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(capabilities.keys.sorted(), id: \.self) { key in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(key): \(capabilities[key] ?? "")")
                            .font(.footnote)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    func pairingCardStyle() -> some View {
        self
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

private struct PairingStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.92)
        }
    }
}
