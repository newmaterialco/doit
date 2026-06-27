import Foundation
import Observation
import Realtime
import Supabase

/// App-scoped onboarding state machine. Decides whether a signed-in user
/// goes straight to the task list or through the invite-code / "creating
/// your agent" flow, and tells `doitApp` when it is safe to start the
/// `TodoStore` and register for push (`isReady`).
///
/// Lifecycle mirrors `TodoStore`: `begin(userID:)` on sign-in,
/// `reset()` on sign-out (AGENTS.md rule 7).
@MainActor
@Observable
final class OnboardingModel {
    enum Phase: Equatable {
        /// Asking the backend whether this user is already provisioned.
        case checking
        /// No provisioning row yet — show the invite code form.
        case inviteEntry
        /// Invite redeemed; the VM-side provisioner is building the agent.
        case creating
        /// Provisioning errored. Retry re-queues it without a fresh code.
        case failed(message: String)
        /// BYO connector mode: show the pairing code/command while waiting for heartbeat.
        case byoPairing(BYOConnectorPrepareResponse, BYOConnectorStatus?)
        case ready
    }

    private(set) var phase: Phase = .checking
    /// Inline error under the invite field (invalid/expired code, network).
    private(set) var inviteError: String?
    private(set) var isBusy = false

    /// Gate for `todoStore.start` / push registration. Once true it stays
    /// true until sign-out, and is cached per-user so returning users skip
    /// the network round-trip on launch.
    private(set) var isReady = false

    private var userID: UUID?
    private var setupMode: AppSetupMode = .hosted
    private var watchTask: Task<Void, Never>?
    private weak var connectivity: ConnectivityMonitor?

    private static func cacheKey(_ userID: UUID, setupMode: AppSetupMode) -> String {
        "onboarding_ready_\(setupMode.rawValue)_\(userID.uuidString)"
    }

    // MARK: - Lifecycle

    func begin(userID: UUID, setupMode: AppSetupMode, connectivity: ConnectivityMonitor) {
        if self.userID == userID, isReady { return }
        reset()
        self.userID = userID
        self.setupMode = setupMode
        self.connectivity = connectivity
        if UserDefaults.standard.bool(forKey: Self.cacheKey(userID, setupMode: setupMode)) {
            markReady()
            return
        }
        phase = .checking
        Task {
            if setupMode == .byoConnector {
                await prepareBYOConnector()
            } else {
                await refreshStatus()
            }
        }
    }

    func reset() {
        watchTask?.cancel()
        watchTask = nil
        userID = nil
        connectivity = nil
        isReady = false
        isBusy = false
        inviteError = nil
        phase = .checking
        setupMode = .hosted
    }

    // MARK: - Actions

    func refreshStatus() async {
        guard userID != nil else { return }
        if setupMode == .byoConnector {
            await refreshBYOStatus()
            return
        }
        do {
            apply(try await OnboardingAPI.status())
        } catch {
            // Transient (offline, cold function): stay in the current phase
            // if it already shows something actionable, otherwise surface
            // the invite form so the user isn't stuck on a spinner.
            print("[onboarding] status failed: \(error)")
            if phase == .checking {
                phase = .inviteEntry
                if connectivity?.reportFailure(error) != true {
                    inviteError = "Couldn't reach the server. Check your connection and try again."
                }
            }
        }
    }

    func prepareBYOConnector() async {
        guard userID != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let prepared = try await OnboardingAPI.prepareBYOConnector()
            phase = .byoPairing(prepared, prepared.connector)
            connectivity?.reportSuccess()
            startWatching()
        } catch {
            print("[onboarding] byo prepare failed: \(error)")
            if connectivity?.reportFailure(error) != true {
                phase = .failed(message: "Couldn't create a connector pairing. Check your connection and try again.")
            }
        }
    }

    func redeem(code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inviteError = "Enter your invite code."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let resp = try await OnboardingAPI.redeem(code: trimmed)
            guard resp.ok else {
                inviteError = "That invite code isn't valid. Double-check it and try again."
                return
            }
            inviteError = nil
            applyProvisioning(resp.provisioning)
        } catch {
            print("[onboarding] redeem failed: \(error)")
            if connectivity?.reportFailure(error) != true {
                inviteError = "Something went wrong. Check your connection and try again."
            }
        }
    }

    /// Retry after a `failed` provisioning run. The redeem RPC flips an
    /// existing `failed` row back to `pending` without consuming an invite
    /// use (the code argument is ignored for users who already redeemed).
    func retry() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let resp = try await OnboardingAPI.redeem(code: "RETRY")
            if resp.ok {
                applyProvisioning(resp.provisioning)
            } else {
                await refreshStatus()
            }
        } catch {
            print("[onboarding] retry failed: \(error)")
            _ = connectivity?.reportFailure(error)
        }
    }

    // MARK: - State transitions

    private func apply(_ resp: OnboardingStatusResponse) {
        connectivity?.reportSuccess()
        if resp.agent_ready {
            markReady()
            return
        }
        applyProvisioning(resp.provisioning)
    }

    private func applyProvisioning(_ provisioning: OnboardingProvisioning?) {
        guard let provisioning else {
            phase = .inviteEntry
            return
        }
        switch provisioning.status {
        case "ready":
            markReady()
        case "failed":
            watchTask?.cancel()
            watchTask = nil
            phase = .failed(
                message: "We couldn't finish setting up your agent. Tap retry and we'll pick up where we left off."
            )
        default:  // pending | provisioning
            phase = .creating
            startWatching()
        }
    }

    private func markReady() {
        watchTask?.cancel()
        watchTask = nil
        if let userID {
            UserDefaults.standard.set(true, forKey: Self.cacheKey(userID, setupMode: setupMode))
        }
        phase = .ready
        isReady = true
    }

    private func refreshBYOStatus() async {
        do {
            let resp = try await OnboardingAPI.byoConnectorStatus()
            connectivity?.reportSuccess()
            if resp.agent_ready {
                markReady()
                return
            }
            if case .byoPairing(let prepared, _) = phase {
                phase = .byoPairing(prepared, resp.connector)
            } else {
                await prepareBYOConnector()
            }
        } catch {
            print("[onboarding] byo status failed: \(error)")
            _ = connectivity?.reportFailure(error)
        }
    }

    // MARK: - Live status (Realtime + polling fallback)

    private func startWatching() {
        guard watchTask == nil, let userID else { return }
        watchTask = Task { await watchLoop(userID: userID) }
    }

    /// Subscribe to the user's `user_provisioning` row and refetch status on
    /// every change. A coarse poll runs alongside as a fallback so a missed
    /// Realtime event can only delay — never strand — the transition.
    private func watchLoop(userID: UUID) async {
        if setupMode == .byoConnector {
            await watchBYOConnectorLoop()
            return
        }
        let filter = "user_id=eq.\(userID.uuidString)"
        while !Task.isCancelled {
            let channel = Supa.client.channel(
                "public:user_provisioning:user=\(userID.uuidString)"
            )
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "user_provisioning",
                filter: filter
            )

            var subscribed = false
            do {
                try await channel.subscribeWithError()
                subscribed = true
            } catch {
                print("[onboarding] realtime subscribe failed: \(error)")
            }

            if subscribed {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in changes {
                            await self.refreshStatus()
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(5))
                            if Task.isCancelled { break }
                            await self.refreshStatus()
                        }
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            } else {
                // Poll-only fallback before retrying the subscription.
                for _ in 0..<6 {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(5))
                    await refreshStatus()
                }
            }

            await Supa.client.removeChannel(channel)
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func watchBYOConnectorLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { break }
            await refreshBYOStatus()
        }
    }
}
