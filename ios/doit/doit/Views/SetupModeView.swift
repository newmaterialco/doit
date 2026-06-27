import SwiftUI

struct SetupModeView: View {
    private static let githubRepoURL = URL(string: "https://github.com/newmaterialco/doit")!

    @Environment(AuthModel.self) private var auth
    @Environment(AppSetupModeStore.self) private var setupMode
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var isStartingBYO = false
    @State private var byoErrorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 24) {
                Spacer(minLength: 0)

                AdaptiveDoitLogo(width: 120)

                VStack(spacing: 8) {
                    Text("How do you want to use Doit?")
                        .font(.title2.weight(.semibold))
                    Text("Choose the setup that matches where your Hermes agent will run.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                VStack(spacing: 12) {
                    SetupModeCard(
                        title: "Use Doit out of the box",
                        subtitle: "Managed setup. We host the agent infrastructure for you.",
                        systemImage: "sparkles",
                        action: { setupMode.choose(.hosted) }
                    )

                    if AppConfig.byoConnectorEnabled {
                        SetupModeCard(
                            title: isStartingBYO ? "Starting BYO setup..." : "Connect my Hermes",
                            subtitle: "Use your existing Hermes on a VPS, Tailscale node, home server, or local machine.",
                            systemImage: isStartingBYO ? "hourglass" : "app.connected.to.app.below.fill",
                            action: { Task { await startBYOSetup() } }
                        )
                    }
                }

                if let byoErrorMessage {
                    Text(byoErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Rectangle()
                    .fill(Color(.separator).opacity(0.5))
                    .frame(height: 1)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    Text("Want to self-host / fork the app? We've open-sourced the repo below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)

                    Button {
                        openURL(Self.githubRepoURL)
                    } label: {
                        HStack(spacing: 10) {
                            Image(colorScheme == .dark ? "github_white" : "github")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                            Text("newmaterialco/doit")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(AppSemanticColors.elevatedSurface, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
                }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .padding(.top, 32)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(AppSemanticColors.screenBackground.ignoresSafeArea())
    }

    private func startBYOSetup() async {
        guard !isStartingBYO else { return }
        isStartingBYO = true
        defer { isStartingBYO = false }
        do {
            setupMode.choose(.byoConnector)
            setupMode.holdForBYOPairing()
            try await auth.signInAnonymously()
            byoErrorMessage = nil
        } catch {
            setupMode.reset()
            byoErrorMessage = "Couldn't start BYO setup. Check your connection and try again."
        }
    }
}

private struct SetupModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct BYOAnonymousStartView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(AppSetupModeStore.self) private var setupMode
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            AdaptiveDoitLogo(width: 110)

            VStack(spacing: 10) {
                Text("Connect your Hermes")
                    .font(.title2.weight(.semibold))
                Text("Continue without Apple. Doit will use your Hermes setup as-is, and your model keys, OAuth connections, memory files, tools, and profile config stay on your machine.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await continueWithoutAccount() }
            } label: {
                if isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue without account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)

            Button("Choose a different setup") {
                setupMode.reset()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 24)
        .background(AppSemanticColors.screenBackground.ignoresSafeArea())
    }

    private func continueWithoutAccount() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await auth.signInAnonymously()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start anonymous BYO setup: \(error.localizedDescription)"
        }
    }
}

struct SelfHostInfoView: View {
    @Environment(AppSetupModeStore.self) private var setupMode

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Self-host / fork")
                .font(.title2.weight(.semibold))
            Text("This path is for developers running their own Supabase/control plane, Apple app configuration, runner, and Hermes setup. Build the app with your own config from the repo docs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose a different setup") {
                setupMode.reset()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.horizontal, 24)
        .background(AppSemanticColors.screenBackground.ignoresSafeArea())
    }
}
