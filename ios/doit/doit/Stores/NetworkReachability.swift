import Foundation
import Network
import Observation

/// Observes network path changes, drives the app-wide "No Connection" toast,
/// and fires when connectivity is restored after an outage. Used by
/// `TodoStore` to reconcile active todos without polling.
@MainActor
@Observable
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "doit.networkReachability")
    private var hadConnectivityFailure = false

    private(set) var isConnected = true

    var showBanner: Bool {
        !isConnected || hadConnectivityFailure
    }

    var onConnectivityRestored: (() async -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let nowConnected = path.status == .satisfied
                let wasConnected = self.isConnected
                self.isConnected = nowConnected
                if nowConnected {
                    self.hadConnectivityFailure = false
                }
                if nowConnected, !wasConnected {
                    print("[network] connectivity restored")
                    await self.onConnectivityRestored?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        isConnected = true
        hadConnectivityFailure = false
    }

    /// Returns `true` when the error is connectivity-related and the toast
    /// should be shown instead of an inline error message.
    @discardableResult
    func reportFailure(_ error: Error) -> Bool {
        guard ConnectivityError.isConnectivityFailure(error) else { return false }
        hadConnectivityFailure = true
        return true
    }

    /// Clears a request-driven failure once a call succeeds while online.
    func reportSuccess() {
        guard isConnected else { return }
        hadConnectivityFailure = false
    }
}
