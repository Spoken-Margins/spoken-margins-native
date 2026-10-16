import Foundation

/// The app's one view of the network (#779), as the code that reacts to it needs to see it. The app's
/// `ConnectivityMonitor` is the real one, built on `NWPathMonitor`; anything that only reads the transport
/// or listens for changes takes this instead, so it can be tested on the host with a hand-driven network.
@MainActor
public protocol ConnectivityProviding: AnyObject {
    var transport: PodcastNetworkTransport { get }
    /// True only when the path is unsatisfied (Airplane Mode, no signal). Until the first update the state is
    /// unknown and counts as online, so nothing is blocked on a guess.
    var isOffline: Bool { get }

    func start()

    /// Calls `handler` on every change, and at once with the current transport if one is already known.
    @discardableResult
    func addObserver(_ handler: @escaping (PodcastNetworkTransport) -> Void) -> UUID

    func removeObserver(_ id: UUID)
}
