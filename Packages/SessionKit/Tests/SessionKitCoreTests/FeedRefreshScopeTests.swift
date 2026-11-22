import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// #4388: how much of Following a launch refresh covers, and that the coordinator fetches stale feeds several at once.
final class FeedRefreshScopeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func subscription(_ n: Int, state: FeedSubscriptionState = .active, refreshedHoursAgo: Double? = nil) -> FeedSubscription {
        let source = SourceIdentity(id: "source-\(n)", kind: .podcastFeed, canonicalURL: "https://feeds\(n).example/feed", host: "feeds\(n).example", title: "Show \(n)")
        return FeedSubscription(id: "show-\(n)", source: source, state: state,
                                lastRefreshAt: refreshedHoursAgo.map { base.addingTimeInterval(-$0 * 3600) }, createdAt: base)
    }

    /// Show n's newest episode is n hours old, so show 1 is first on screen.
    private func entry(for n: Int) -> FeedEntry {
        FeedEntry(id: "entry-\(n)", subscriptionId: "show-\(n)", canonicalURL: "https://feeds\(n).example/e", audioURL: "https://feeds\(n).example/e.mp3",
                  title: "Episode \(n)", publishedAt: base.addingTimeInterval(-Double(n) * 3600))
    }

    private func seeded(_ count: Int, muted: Set<Int> = []) throws -> InMemorySessionRepository {
        let repository = InMemorySessionRepository()
        for n in 1...count {
            try repository.saveFeedSubscription(subscription(n, state: muted.contains(n) ? .muted : .active))
            try repository.saveFeedEntry(entry(for: n))
        }
        return repository
    }

    func testAllFeedsScopeCoversEveryFeed() throws {
        let repository = try seeded(15)
        let ids = FeedRefreshScope.allFeeds.subscriptionIDs(subscriptions: try repository.loadFeedSubscriptions(), entries: try repository.loadFeedEntries(subscriptionId: nil))
        XCTAssertNil(ids)
    }

    func testTheFirstScreenIsTheTenShowsWithTheNewestEpisodes() throws {
        let repository = try seeded(41)
        let ids = FeedRefreshScope.firstScreen.subscriptionIDs(subscriptions: try repository.loadFeedSubscriptions(), entries: try repository.loadFeedEntries(subscriptionId: nil))
        XCTAssertEqual(ids, Set((1...10).map { "show-\($0)" }))
    }

    func testQuietShowsAreNotOnTheFirstScreenAndFewShowsAreAllCovered() throws {
        let repository = try seeded(12, muted: [1, 2])
        let ids = FeedRefreshScope.firstScreen.subscriptionIDs(subscriptions: try repository.loadFeedSubscriptions(), entries: try repository.loadFeedEntries(subscriptionId: nil))
        XCTAssertEqual(ids, Set((3...12).map { "show-\($0)" }), "a Quiet show sits below the rows, so the next shows move up")
        let few = try seeded(3)
        XCTAssertEqual(FeedRefreshScope.firstScreen.subscriptionIDs(subscriptions: try few.loadFeedSubscriptions(), entries: try few.loadFeedEntries(subscriptionId: nil)), ["show-1", "show-2", "show-3"])
        XCTAssertEqual(FeedRefreshScope.firstScreen.subscriptionIDs(subscriptions: [], entries: []), [])
    }

    func testOnlyLowPowerModeNarrowsTheLaunchPass() {
        XCTAssertEqual(FeedRefreshScope.atLaunch(lowPowerMode: true), .firstScreen)
        XCTAssertEqual(FeedRefreshScope.atLaunch(lowPowerMode: false), .allFeeds)
    }

    // MARK: - The coordinator

    private func coordinator(_ repository: InMemorySessionRepository) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowFeedURLProtocol.self]
        return FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: nil)
    }

    /// Fails without the fix: the old loop fetched one feed at a time, so at most one was ever in flight.
    /// The feeds are held open until the test sees the cap's worth in flight at once, so the result does not depend on
    /// how fast a busy runner starts the requests (#4705: a 50 ms timer let a slow start finish one before the next began).
    func testStaleFeedsAreFetchedSeveralAtOnceButNeverAboveTheCap() async throws {
        let repository = InMemorySessionRepository()
        for n in 1...12 { try repository.saveFeedSubscription(subscription(n, refreshedHoursAgo: 7)) }
        SlowFeedURLProtocol.reset(holding: true)
        let followed = coordinator(repository)
        let now = base
        let refresh = Task { await followed.refreshStale(now: now, maximumConcurrent: 4) }

        // Four held open at once means the loop fetches in parallel; a loop that fetches one at a time never gets there.
        let reachedTheCap = await waitUntil { SlowFeedURLProtocol.heldCount >= 4 }
        let heldWhileWaiting = SlowFeedURLProtocol.heldCount
        SlowFeedURLProtocol.releaseAll()
        _ = await refresh.value

        XCTAssertTrue(reachedTheCap, "only \(heldWhileWaiting) feeds were in flight together; expected 4")
        XCTAssertEqual(SlowFeedURLProtocol.fetchedHosts.count, 12, "every stale feed is fetched once")
        XCTAssertEqual(SlowFeedURLProtocol.peakInFlight, 4, "four at a time, never more")
        for subscription in try repository.loadFeedSubscriptions() {
            XCTAssertEqual(subscription.lastRefreshAt, base, "\(subscription.id) was marked refreshed")
        }
    }

    /// A deadline is only a ceiling (docs/testing.md "Waiting in tests"); the answer is the state, not the elapsed time.
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func testFreshFeedsAreNotFetched() async throws {
        let repository = InMemorySessionRepository()
        for n in 1...6 { try repository.saveFeedSubscription(subscription(n, refreshedHoursAgo: n <= 4 ? 1 : 7)) }
        SlowFeedURLProtocol.reset()

        _ = await coordinator(repository).refreshStale(now: base)

        XCTAssertEqual(SlowFeedURLProtocol.fetchedHosts, ["feeds5.example", "feeds6.example"])
    }

    /// Fails without the fix: Low Power Mode used to refresh all 41 feeds at launch.
    func testTheFirstScreenScopeRefreshesTenOfFortyOneAndLeavesTheRestStale() async throws {
        let repository = try seeded(41)
        for n in 1...41 {
            var stale = subscription(n, refreshedHoursAgo: 7)
            stale.state = .active
            try repository.saveFeedSubscription(stale)
        }
        SlowFeedURLProtocol.reset()

        _ = await coordinator(repository).refreshStale(now: base, scope: .firstScreen)

        XCTAssertEqual(SlowFeedURLProtocol.fetchedHosts, Set((1...10).map { "feeds\($0).example" }))
        let byID = Dictionary(uniqueKeysWithValues: try repository.loadFeedSubscriptions().map { ($0.id, $0) })
        XCTAssertEqual(byID["show-3"]?.lastRefreshAt, base)
        XCTAssertEqual(byID["show-30"]?.lastRefreshAt, base.addingTimeInterval(-7 * 3600), "a feed off the first screen stays stale for a later pass")

        SlowFeedURLProtocol.reset()
        _ = await coordinator(repository).refreshStale(now: base)
        XCTAssertEqual(SlowFeedURLProtocol.fetchedHosts, Set((11...41).map { "feeds\($0).example" }), "the next full pass picks up the rest")
    }
}

/// Answers every `*.example` feed with an empty JSON feed after a short wait, and records how many were open at once.
/// With `reset(holding: true)` it answers nothing until `releaseAll()`, so a test controls when requests finish.
private final class SlowFeedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var peak = 0
    nonisolated(unsafe) private static var hosts: Set<String> = []
    nonisolated(unsafe) private static var holding = false
    nonisolated(unsafe) private static var held: [Finisher] = []

    static func reset(holding: Bool = false) {
        lock.lock(); inFlight = 0; peak = 0; hosts = []; self.holding = holding; held = []; lock.unlock()
    }
    static var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    /// Answers every held request and stops holding, so later requests answer after the short wait as usual.
    static func releaseAll() {
        lock.lock(); holding = false; let parked = held; held = []; lock.unlock()
        for finish in parked { finish.run() }
    }
    static var peakInFlight: Int { lock.lock(); defer { lock.unlock() }; return peak }
    static var fetchedHosts: Set<String> { lock.lock(); defer { lock.unlock() }; return hosts }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".example") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.inFlight += 1
        Self.peak = max(Self.peak, Self.inFlight)
        Self.hosts.insert(request.url?.host ?? "")
        let finish = Finisher(urlProtocol: self)
        if Self.holding {
            Self.held.append(finish)
            Self.lock.unlock()
            return
        }
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            finish.run()
        }
    }

    /// Carries the protocol to the timer; URLProtocol is not Sendable, and only this timer touches it afterwards.
    fileprivate struct Finisher: @unchecked Sendable {
        let urlProtocol: SlowFeedURLProtocol
        func run() { urlProtocol.respond() }
    }

    fileprivate func respond() {
        do {
            Self.lock.lock(); Self.inFlight -= 1; Self.lock.unlock()
            let data = Data(#"{"version":"https://jsonfeed.org/version/1.1","title":"Show","items":[]}"#.utf8)
            guard let url = request.url, let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/feed+json", "Content-Length": "\(data.count)"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
