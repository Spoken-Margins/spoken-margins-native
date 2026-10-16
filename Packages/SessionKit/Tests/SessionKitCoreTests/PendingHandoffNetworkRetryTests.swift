import Foundation
import XCTest
@testable import SessionKit

/// A network the test drives by hand. It mirrors the app's monitor: observers hear every change, and hear
/// the current transport at once if one was already reported.
@MainActor
private final class ManualConnectivity: ConnectivityProviding {
    private(set) var transport: PodcastNetworkTransport = .other
    private(set) var isOffline = false
    private(set) var startCount = 0
    private var hasReported = false
    private var observers: [UUID: (PodcastNetworkTransport) -> Void] = [:]

    var observerCount: Int { observers.count }

    func start() { startCount += 1 }

    @discardableResult
    func addObserver(_ handler: @escaping (PodcastNetworkTransport) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        if hasReported { handler(transport) }
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func report(_ transport: PodcastNetworkTransport) {
        hasReported = true
        self.transport = transport
        isOffline = transport == .unavailable
        for handler in Array(observers.values) { handler(transport) }
    }
}

@MainActor
final class PendingHandoffNetworkRetryTests: XCTestCase {
    private func makeRetry(
        waiting: Int,
        network: ManualConnectivity,
        count: @escaping () -> Void
    ) -> PendingHandoffNetworkRetry {
        let retry = PendingHandoffNetworkRetry()
        retry.update(waitingCount: waiting, connectivity: network, retry: count)
        return retry
    }

    func testRetriesWhenTheNetworkComesBackAfterGoingOffline() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 1, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }

        network.report(.wifi)
        network.report(.unavailable)
        XCTAssertEqual(retries, 0, "going offline is not a reason to retry")
        network.report(.cellular)
        XCTAssertEqual(retries, 1)
    }

    func testTheFirstReportNeverRetries() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 1, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }

        network.report(.wifi)
        XCTAssertEqual(retries, 0, "a link that timed out on a working connection waits for the next activation")
    }

    func testAnOfflineFirstReportThenOnlineRetries() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 2, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }

        network.report(.unavailable)
        network.report(.wifi)
        XCTAssertEqual(retries, 1)
    }

    func testMovingBetweenOnlineTransportsDoesNotRetry() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 1, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }

        network.report(.wifi)
        network.report(.cellular)
        network.report(.other)
        XCTAssertEqual(retries, 0)
    }

    func testNothingWaitingNeverStartsListening() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 0, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }

        XCTAssertEqual(network.startCount, 0)
        XCTAssertEqual(network.observerCount, 0)
        network.report(.unavailable)
        network.report(.wifi)
        XCTAssertEqual(retries, 0)
    }

    func testListensOnceHoweverOftenItIsUpdated() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 1, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }
        retry.update(waitingCount: 3, connectivity: network) { retries += 1 }
        retry.update(waitingCount: 1, connectivity: network) { retries += 1 }
        XCTAssertEqual(retries, 0)

        XCTAssertEqual(network.startCount, 1)
        XCTAssertEqual(network.observerCount, 1)
    }

    func testTheLatestRetryClosureIsTheOneCalled() async {
        let network = ManualConnectivity()
        var first = 0
        var second = 0
        let retry = makeRetry(waiting: 1, network: network) { first += 1 }
        defer { withExtendedLifetime(retry) {} }
        retry.update(waitingCount: 1, connectivity: network) { second += 1 }

        network.report(.unavailable)
        network.report(.wifi)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    func testOnceTheQueueDrainsAReturnedNetworkDoesNotRetry() async {
        let network = ManualConnectivity()
        var retries = 0
        let retry = makeRetry(waiting: 1, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }
        network.report(.unavailable)
        retry.update(waitingCount: 0, connectivity: network) { retries += 1 }

        network.report(.wifi)
        XCTAssertEqual(retries, 0, "no link is waiting any more")
    }

    func testAnObserverAddedAfterAReportHearsTheCurrentTransportAtOnce() async {
        let network = ManualConnectivity()
        network.report(.unavailable)
        var retries = 0
        let retry = makeRetry(waiting: 1, network: network) { retries += 1 }
        defer { withExtendedLifetime(retry) {} }

        XCTAssertEqual(retries, 0)
        network.report(.wifi)
        XCTAssertEqual(retries, 1, "the offline state heard on joining counts as the offline half of the change")
    }
}
