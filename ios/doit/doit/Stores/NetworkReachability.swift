import Foundation
import Network

/// Observes network path changes and fires when connectivity is restored
/// after an outage. Used by `TodoStore` to reconcile active todos without
/// polling.
@MainActor
final class NetworkReachability {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "doit.networkReachability")
    private var isSatisfied = true

    var onConnectivityRestored: (() async -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let nowSatisfied = path.status == .satisfied
                let wasSatisfied = self.isSatisfied
                self.isSatisfied = nowSatisfied
                if nowSatisfied, !wasSatisfied {
                    print("[network] connectivity restored")
                    await self.onConnectivityRestored?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        isSatisfied = true
    }
}
