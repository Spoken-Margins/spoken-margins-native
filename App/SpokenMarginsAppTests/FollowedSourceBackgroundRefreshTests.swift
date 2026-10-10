#if canImport(BackgroundTasks) && canImport(UIKit)
import BackgroundTasks
import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// The background feed refresh (#170): the system task runs the same stale-only refresh as the
/// foreground, asks for the next run, and stops cleanly when iOS says time is up.
@MainActor
final class FollowedSourceBackgroundRefreshTests: XCTestCase {
    private let feedURL = "https://backgroundrefresh.example/feed.json"
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        BackgroundFeedURLProtocol.episodes = [1, 2]
        BackgroundFeedURLProtocol.requestCount = 0
    }

    private func coordinator(_ repository: InMemorySessionRepository) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundFeedURLProtocol.self]
        return FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration))
    }

    private func controller(submitted: SubmittedRequests) -> FollowedSourceBackgroundRefreshController {
        FollowedSourceBackgroundRefreshController(
            submit: { submitted.requests.append($0) },
            cancelPending: { submitted.cancelCount += 1 },
            now: { [fixedNow] in fixedNow }
        )
    }

    /// Follows the show, then backdates its last refresh by `hours`.
    private func followedShow(
        _ coordinator: FollowedSourceCoordinator, _ repository: InMemorySessionRepository, refreshedHoursAgo hours: Double
    ) async throws -> FeedSubscription {
        var subscription = try await coordinator.follow(urlString: feedURL)
        subscription.lastRefreshAt = Date().addingTimeInterval(-hours * 60 * 60)
        try repository.saveFeedSubscription(subscription)
        return subscription
    }

    private func titles(_ coordinator: FollowedSourceCoordinator) async throws -> [String] {
        try await coordinator.entries().map(\.title).sorted()
    }

    func testAStaleFeedGetsItsNewEpisodeOnceAndASecondRunAddsNothing() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        var subscription = try await followedShow(coordinator, repository, refreshedHoursAgo: 7)
        let submitted = SubmittedRequests()
        let controller = controller(submitted: submitted)
        controller.install { await coordinator.refreshStale() }

        BackgroundFeedURLProtocol.episodes = [1, 2, 3]
        let first = FakeRefreshTask()
        await controller.handle(first)
        let afterFirst = try await titles(coordinator)
        XCTAssertEqual(afterFirst, ["Episode 1", "Episode 2", "Episode 3"])
        XCTAssertEqual(first.completions, [true])

        // Right after a refresh the feed is fresh, so the next run doesn't fetch it.
        let requestsAfterFirst = BackgroundFeedURLProtocol.requestCount
        let skipped = FakeRefreshTask()
        await controller.handle(skipped)
        XCTAssertEqual(BackgroundFeedURLProtocol.requestCount, requestsAfterFirst, "the feed was fresh, so it wasn't fetched again")
        XCTAssertEqual(skipped.completions, [true])

        // Stale again with nothing new: the fetch happens and saves no duplicate.
        subscription = try XCTUnwrap(repository.loadFeedSubscriptions().first)
        subscription.lastRefreshAt = Date().addingTimeInterval(-7 * 60 * 60)
        try repository.saveFeedSubscription(subscription)
        let second = FakeRefreshTask()
        await controller.handle(second)
        XCTAssertGreaterThan(BackgroundFeedURLProtocol.requestCount, requestsAfterFirst, "a stale feed is fetched")
        let afterSecond = try await titles(coordinator)
        XCTAssertEqual(afterSecond, ["Episode 1", "Episode 2", "Episode 3"], "no duplicate entry")
        XCTAssertEqual(second.completions, [true])
    }

    func testAFreshFeedIsNotFetched() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        _ = try await followedShow(coordinator, repository, refreshedHoursAgo: 1)
        let requestsBefore = BackgroundFeedURLProtocol.requestCount
        let controller = controller(submitted: SubmittedRequests())
        controller.install { await coordinator.refreshStale() }

        BackgroundFeedURLProtocol.episodes = [1, 2, 3]
        let task = FakeRefreshTask()
        await controller.handle(task)
        XCTAssertEqual(BackgroundFeedURLProtocol.requestCount, requestsBefore)
        let waiting = try await titles(coordinator)
        XCTAssertEqual(waiting, ["Episode 1", "Episode 2"], "Episode 3 waits for the next stale refresh")
        XCTAssertEqual(task.completions, [true])
    }

    func testEachRunAsksForTheNextRefreshAboutSixHoursOut() async throws {
        let submitted = SubmittedRequests()
        let controller = controller(submitted: submitted)
        controller.install {}
        await controller.handle(FakeRefreshTask())

        let request = try XCTUnwrap(submitted.requests.last)
        XCTAssertEqual(request.identifier, "com.spokenmargins.native.feed-refresh")
        XCTAssertEqual(request.earliestBeginDate, fixedNow.addingTimeInterval(6 * 60 * 60))
        XCTAssertEqual(submitted.cancelCount, 1, "the earlier request is withdrawn before the new one goes in")

        controller.schedule(enabled: false)
        XCTAssertEqual(submitted.requests.count, 1, "with nothing followed, no new request is made")
        XCTAssertEqual(submitted.cancelCount, 2, "and the pending one is withdrawn")
    }

    func testExpiryCancelsTheRefreshAndCompletesTheTaskUnsuccessfully() async throws {
        let submitted = SubmittedRequests()
        let controller = controller(submitted: submitted)
        let started = expectation(description: "the refresh started")
        let stopped = Flag()
        controller.install {
            started.fulfill()
            while !Task.isCancelled { await Task.yield() }
            stopped.set()
        }
        let task = FakeRefreshTask()
        let handled = Task { await controller.handle(task) }
        await fulfillment(of: [started], timeout: 10)
        let expire = try XCTUnwrap(task.expiration, "the handler is set before the refresh runs")
        expire()
        await handled.value

        XCTAssertTrue(stopped.isSet, "expiry cancelled the refresh")
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(submitted.requests.count, 1, "the next refresh was requested even though this one was cut short")
    }

    func testATaskWithNothingInstalledStillRequestsTheNextRefresh() async throws {
        let submitted = SubmittedRequests()
        let task = FakeRefreshTask()
        await controller(submitted: submitted).handle(task)
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(submitted.requests.count, 1)
    }

    func testACancelledRefreshStopsInsteadOfFailingEveryFeedLeft() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        let subscription = try await followedShow(coordinator, repository, refreshedHoursAgo: 7)

        let cancelled = Task { () -> [FeedEntry] in
            while !Task.isCancelled { await Task.yield() }
            return await coordinator.refreshStale()
        }
        cancelled.cancel()
        _ = await cancelled.value

        XCTAssertNil(try repository.loadFeedRefreshState(subscriptionId: subscription.id), "no failed refresh was recorded")
    }
}

private final class SubmittedRequests {
    var requests: [BGAppRefreshTaskRequest] = []
    var cancelCount = 0
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class FakeRefreshTask: FeedRefreshBackgroundTask, @unchecked Sendable {
    private let lock = NSLock()
    private var storedExpiration: (@Sendable () -> Void)?
    private var storedCompletions: [Bool] = []

    var expiration: (@Sendable () -> Void)? { lock.withLock { storedExpiration } }
    var completions: [Bool] { lock.withLock { storedCompletions } }

    func onExpiration(_ handler: @escaping @Sendable () -> Void) { lock.withLock { storedExpiration = handler } }
    func clearExpiration() { lock.withLock { storedExpiration = nil } }
    func setTaskCompleted(success: Bool) { lock.withLock { storedCompletions.append(success) } }
}

/// A JSON feed whose episode list each test sets, counting the fetches it serves.
private final class BackgroundFeedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var episodes: [Int] = []
    private static let counter = NSLock()
    nonisolated(unsafe) private static var served = 0
    static var requestCount: Int {
        get { counter.withLock { served } }
        set { counter.withLock { served = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "backgroundrefresh.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter.withLock { Self.served += 1 }
        let items = Self.episodes.map { n in
            """
            {"id":"episode-\(n)","url":"https://backgroundrefresh.example/episodes/\(n)","title":"Episode \(n)","date_published":"2026-09-\(String(format: "%02d", n))T12:00:00Z","attachments":[{"url":"https://backgroundrefresh.example/episode-\(n).mp3","mime_type":"audio/mpeg"}]}
            """
        }.joined(separator: ",")
        let data = Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"Background Show","items":[\(items)]}
        """.utf8)
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

    override func stopLoading() {}
}
#endif
