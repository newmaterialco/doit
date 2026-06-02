import AuthenticationServices
import SwiftUI

struct IntegrationsView: View {
    @State private var toolkits: [Toolkit] = []
    @State private var loading = true
    @State private var error: String?
    @State private var busySlug: String?
    @State private var oauthSession: ASWebAuthenticationSession?

    init() {
        let cachedToolkits = IntegrationsAPI.cachedToolkits ?? []
        _toolkits = State(initialValue: cachedToolkits)
        _loading = State(initialValue: cachedToolkits.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loading && toolkits.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                if !toolkits.isEmpty {
                    ForEach(toolkits) { tk in
                        ToolkitRow(
                            toolkit: tk,
                            busy: busySlug == tk.slug,
                            onConnect: { Task { await connect(tk) } },
                            onDisconnect: { Task { await disconnect(tk) } }
                        )
                        .padding(.horizontal, 28)
                        Divider()
                            .padding(.horizontal, 28)
                    }
                    Text("Connected accounts let the agent act on your behalf. We never see your password - Composio manages secure OAuth tokens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                }
            }
        }
        .background(Color.white.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(showSpinner: toolkits.isEmpty) }
        .refreshable { await load() }
    }

    private func load(showSpinner: Bool = true) async {
        if showSpinner {
            loading = true
        }
        defer { loading = false }
        do {
            toolkits = try await IntegrationsAPI.list()
            error = nil
        } catch {
            self.error = "Couldn't load integrations: \(error.localizedDescription)"
        }
    }

    private func connect(_ tk: Toolkit) async {
        busySlug = tk.slug
        defer { busySlug = nil }
        do {
            let result = try await IntegrationsAPI.connect(toolkit: tk.slug)
            guard let url = URL(string: result.redirect_url) else {
                self.error = "Got an invalid authorization URL."
                return
            }
            await runOAuth(url: url)
            await load()
        } catch {
            self.error = "Couldn't start connection: \(error.localizedDescription)"
        }
    }

    private func disconnect(_ tk: Toolkit) async {
        guard let cid = tk.connection_id else { return }
        busySlug = tk.slug
        defer { busySlug = nil }
        do {
            try await IntegrationsAPI.disconnect(connectionID: cid)
            await load(showSpinner: false)
        } catch {
            self.error = "Couldn't disconnect: \(error.localizedDescription)"
        }
    }

    private func runOAuth(url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
                cont.resume()
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = PresentationContextProvider.shared
            self.oauthSession = session
            if !session.start() {
                cont.resume()
            }
        }
    }
}

private struct ToolkitRow: View {
    let toolkit: Toolkit
    let busy: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ToolkitLogo(assetName: toolkit.slug)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(toolkit.name).font(.headline)
                    if !toolkit.isConnectable {
                        Text("Available")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color(.systemGray))
                    } else if toolkit.connected {
                        Text("Connected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.green)
                    }
                }
                Text(toolkit.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if busy {
                ProgressView()
            } else if toolkit.isConnectable && toolkit.connected {
                Menu {
                    Button("Disconnect", role: .destructive, action: onDisconnect)
                } label: {
                    EllipsisMenuIcon()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if toolkit.isConnectable {
                Button("Connect", action: onConnect)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    }
            }
        }
        .padding(.vertical, 26)
    }
}

private struct EllipsisMenuIcon: View {
    var body: some View {
        VStack(spacing: 3) {
            Circle().fill(Color(.systemGray))
            Circle().fill(Color(.systemGray))
            Circle().fill(Color(.systemGray))
        }
        .frame(width: 4, height: 18)
        .frame(width: 34, height: 34)
    }
}

private struct ToolkitLogo: View {
    let assetName: String

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 26, height: 26)
    }
}
