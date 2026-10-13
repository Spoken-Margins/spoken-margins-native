import Foundation
import SessionKit

/// Retries links that were waiting for a connection as soon as the network comes back (#1546). It listens to
/// the app's one `ConnectivityMonitor` and fires only on a change from offline to online, never on the first
/// report, so a link that timed out on a working connection waits for the next activation instead of looping.
@MainActor
final class PendingHandoffNetworkRetry {
    private var observer: UUID?
    private var lastTransport: PodcastNetworkTransport?
    private var isWaiting = false
    private var retry: (() -> Void)?

    /// Call after each drain with the number of links still waiting. Starts listening the first time one waits.
    func update(waitingCount: Int, connectivity: ConnectivityMonitor, retry: @escaping () -> Void) {
        isWaiting = waitingCount > 0
        self.retry = retry
        guard isWaiting, observer == nil else { return }
        connectivity.start()
        observer = connectivity.addObserver { [weak self] transport in
            self?.transportChanged(to: transport)
        }
    }

    func transportChanged(to transport: PodcastNetworkTransport) {
        let cameBack = lastTransport == .unavailable && transport != .unavailable
        lastTransport = transport
        if cameBack, isWaiting { retry?() }
    }
}
