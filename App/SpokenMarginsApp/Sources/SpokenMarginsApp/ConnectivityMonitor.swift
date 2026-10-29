import Foundation
import Network
import SessionKit

/// The app's one view of the network (#779). The podcast downloader reacts to its transport (Wi-Fi-only
/// automatic downloads, "Waiting for Wi-Fi"), and the pre-play check reads `isOffline` so a streamed-only
/// episode can say it isn't downloaded instead of stalling.
///
/// Shared, so it is started once and never cancelled while the app runs: the downloader is rebuilt when the
/// store changes, and a cancelled `NWPathMonitor` can't be restarted.
@MainActor
final class ConnectivityMonitor: ObservableObject, ConnectivityProviding {
    @Published private(set) var transport: PodcastNetworkTransport = .other
    /// True only when the path is unsatisfied (Airplane Mode, no signal). Until the first update the state is
    /// unknown and counts as online, so nothing is blocked on a guess.
    @Published private(set) var isOffline = false
    /// Mobile data or a personal hotspot, and Low Data Mode. Unknown counts as neither until the first update.
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.spokenmargins.connectivity")
    private var isStarted = false
    /// False until the first path update, so a caller that must not act on a guess can wait for it.
    private(set) var hasReported = false
    private var observers: [UUID: (PodcastNetworkTransport) -> Void] = [:]

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let transport = Self.transport(for: path)
            let isOffline = path.status == .unsatisfied
            let isExpensive = path.isExpensive, isConstrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.update(transport: transport, isOffline: isOffline, isExpensive: isExpensive, isConstrained: isConstrained)
            }
        }
        monitor.start(queue: queue)
    }

    /// Calls `handler` on every change, and at once with the current transport if one is already known.
    @discardableResult
    func addObserver(_ handler: @escaping (PodcastNetworkTransport) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        if hasReported { handler(transport) }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Path updates land here; tests call it directly to inject a network state.
    func update(transport: PodcastNetworkTransport, isOffline: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        hasReported = true
        self.transport = transport
        self.isOffline = isOffline
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        for handler in Array(observers.values) { handler(transport) }
    }

    nonisolated static func transport(for path: NWPath) -> PodcastNetworkTransport {
        if path.status != .satisfied { return .unavailable }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}
