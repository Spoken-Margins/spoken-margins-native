import XCTest
@testable import SessionKit
import SessionKitFeeds
@testable import SpokenMarginsApp

/// B1 M1: a fresh install opens the podcast drawer once; it works offline from the bundled
/// snapshot; one tap follows and the row shows it.
@MainActor
final class CatalogDrawerTests: XCTestCase {
    private final class FollowLog {
        var feeds: [String] = []
        var subscriptions: [FeedSubscription] = []
        /// Feeds that settle on another URL once followed.
        var moves: [String: String] = [:]
        var failing = false
        var subscriptionReads = 0
    }

    private func makeDrawer(
        defaults: UserDefaults, log: FollowLog, searcher: PodcastNameSearch? = nil,
        startFirstListen: (@MainActor ([String]) async -> Void)? = nil
    ) throws -> CatalogDrawerModel {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"), "catalog snapshot is bundled")
        let cache = FileManager.default.temporaryDirectory.appending(path: "catalog-drawer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        // Offline: every remote fetch fails, so the drawer must run from the bundled snapshot.
        let store = SourceCatalogStore(bundledCatalogURL: bundled, cacheDirectory: cache) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        return CatalogDrawerModel(
            store: store,
            defaults: defaults,
            subscriptions: {
                log.subscriptionReads += 1
                return log.subscriptions
            },
            follow: { feedURL in
                if log.failing { throw URLError(.timedOut) }
                log.feeds.append(feedURL)
                let sourceId = "source-\(log.feeds.count)"
                let settled = log.moves[feedURL] ?? feedURL
                log.subscriptions.append(FeedSubscription(
                    id: "subscription-\(log.feeds.count)",
                    source: SourceIdentity(id: sourceId, kind: .podcastFeed, canonicalURL: settled, host: URL(string: settled)?.host ?? "")
                ))
                return sourceId
            },
            searcher: searcher,
            startFirstListen: startFirstListen
        )
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "CatalogDrawerTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// #2851: Done on the first-run opening plays the first pick, by tap order, once its follow has landed.
    func testDoneOnTheFirstRunOpeningStartsTheFirstListenWithPicksInTapOrder() async throws {
        let log = FollowLog()
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log) { started.append($0) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        await drawer.load()
        let picks = Array(drawer.entries.prefix(2))
        drawer.toggleFollow(picks[1])
        drawer.toggleFollow(picks[0])

        drawer.finish()
        XCTAssertFalse(drawer.isPresented)
        await drawer.playFirstListenIfRequested()

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.count, 2)
        XCTAssertEqual(started.first, ["source-1", "source-2"], "waits for both follows, in the order tapped")
        XCTAssertEqual(log.feeds, [picks[1].feedURL, picks[0].feedURL])

        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started.count, 1, "plays once")
    }

    func testDoneWithNothingFollowedStartsTheFirstListenWithNoPicksSoTheWelcomeSamplePlays() async throws {
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog()) { started.append($0) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.finish()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [[]])
    }

    func testAFailedFollowIsNotAPickAndASwipeOrAFollowingOpeningDoesNotPlay() async throws {
        let log = FollowLog()
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log) { started.append($0) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        await drawer.load()
        log.failing = true
        drawer.toggleFollow(try XCTUnwrap(drawer.entries.first))
        drawer.finish()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [[]], "the failed follow is dropped from the picks")

        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.isPresented = false // swiped away
        await drawer.playFirstListenIfRequested()
        drawer.present() // from Following
        drawer.finish()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started.count, 1)
    }

    func testFreshInstallOpensOnceOfflineAndFollowsFiveInFiveTaps() async throws {
        let defaults = try freshDefaults()
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: defaults, log: log)

        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        XCTAssertTrue(drawer.isPresented)
        await drawer.load()
        XCTAssertGreaterThanOrEqual(drawer.entries.count, 100)
        XCTAssertGreaterThanOrEqual(drawer.subjects.count, 8)

        let picks = Array(drawer.entries.prefix(5))
        for entry in picks { drawer.toggleFollow(entry) } // one tap each
        for _ in 0..<100 where drawer.followedCount < 5 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.followedCount, 5)
        XCTAssertEqual(log.feeds, picks.map(\.feedURL))
        XCTAssertTrue(picks.allSatisfy { drawer.state(for: $0) == .followed })

        drawer.toggleFollow(picks[0])
        XCTAssertEqual(log.feeds.count, 5, "tapping a followed show doesn't follow it twice")

        drawer.markSeen()
        let again = try makeDrawer(defaults: defaults, log: log)
        again.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        XCTAssertFalse(again.isPresented, "opens by itself only once")
    }

    /// #224 lane FAIL: after a relaunch, one of five followed shows (its feed had moved) showed
    /// "Follow" again. The drawer keeps the followed source's id, not only the feed URL.
    func testRelaunchStillShowsAShowWhoseFeedMovedAsFollowed() async throws {
        let defaults = try freshDefaults()
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: defaults, log: log)
        await drawer.load()
        let entry = try XCTUnwrap(drawer.entries.first)
        log.moves[entry.feedURL] = "https://feeds.example.net/moved/feed.xml"
        drawer.toggleFollow(entry)
        for _ in 0..<100 where drawer.followedCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.state(for: entry), .followed)

        let relaunched = try makeDrawer(defaults: defaults, log: log)
        await relaunched.load()
        XCTAssertEqual(relaunched.state(for: entry), .followed, "still followed after a relaunch")
        log.subscriptions.removeAll()
        XCTAssertNil(relaunched.state(for: entry), "unfollowed in Following: shows Follow again")
    }

    /// #646: follow a show, unfollow it in Following, and open the drawer again in the same app
    /// run. The one long-lived drawer still said Following and ignored a tap, because its
    /// remembered success outranked the live subscriptions.
    func testAShowUnfollowedInFollowingCanBeFollowedAgainWithoutARelaunch() async throws {
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log)
        drawer.present()
        await drawer.load()
        let entry = try XCTUnwrap(drawer.entries.first)
        drawer.toggleFollow(entry)
        for _ in 0..<100 where drawer.followedCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.state(for: entry), .followed)

        drawer.isPresented = false
        drawer.markSeen()
        log.subscriptions.removeAll() // unfollowed in Following
        drawer.present()

        XCTAssertNil(drawer.state(for: entry), "shows Follow again")
        XCTAssertNil(drawer.followStates(for: drawer.entries)[entry.id])
        drawer.toggleFollow(entry)
        for _ in 0..<100 where drawer.followedCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.feeds, [entry.feedURL, entry.feedURL], "the second tap really follows it again")
        XCTAssertEqual(log.subscriptions.count, 1)
        XCTAssertEqual(drawer.state(for: entry), .followed)
    }

    /// #661 (Test Desk): following One Useful Thing from the Writers row said "Following 1 show".
    func testFooterNamesANewsletterFollowedFromWritersAsANewsletter() async throws {
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log)
        await drawer.load()
        XCTAssertNil(drawer.followedSummary, "no footer before anything is followed")
        drawer.selectedSubject = "writers"
        let newsletter = try XCTUnwrap(drawer.entries.first)
        XCTAssertEqual(newsletter.contentKind, .newsletter)
        drawer.toggleFollow(newsletter)
        for _ in 0..<100 where drawer.followedCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.followedSummary, "Following 1 newsletter")

        drawer.selectedSubject = nil
        let show = try XCTUnwrap(drawer.entries.first { $0.contentKind == .podcast })
        drawer.toggleFollow(show)
        for _ in 0..<100 where drawer.followedCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.followedSummary, "Following 1 show and 1 newsletter")
    }

    /// #246 (found on the phone): the drawer stuttered while scrolling. Every row worked out its
    /// follow state twice per render, and each time read the recorded follows from UserDefaults and
    /// every subscription again. One pass over the whole catalog now reads subscriptions once.
    func testOnePassOverTheCatalogReadsSubscriptionsOnce() async throws {
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log)
        await drawer.load()
        let entries = drawer.entries
        XCTAssertGreaterThanOrEqual(entries.count, 100)
        drawer.toggleFollow(entries[0])
        for _ in 0..<100 where drawer.followedCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        log.subscriptions.append(FeedSubscription(
            id: "subscription-elsewhere",
            source: SourceIdentity(id: "source-elsewhere", kind: .podcastFeed, canonicalURL: entries[2].feedURL, host: "example")
        ))

        log.subscriptionReads = 0
        let states = drawer.followStates(for: entries)
        XCTAssertLessThanOrEqual(log.subscriptionReads, 1, "one pass over \(entries.count) rows")
        XCTAssertEqual(states[entries[0].id], .followed, "followed from the drawer")
        XCTAssertNil(states[entries[1].id])
        XCTAssertEqual(states[entries[2].id], .followed, "followed another way")
        XCTAssertEqual(states.count, 2)
    }

    /// #470: a Writers entry follows through the same path as a podcast and is stored as an
    /// article feed, so its posts arrive in Following.
    func testFollowingAWriterCreatesAnArticleFeedSubscription() async throws {
        let repository = InMemorySessionRepository()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubstackFeedURLProtocol.self]
        let coordinator = FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: .app)
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "catalog-drawer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        let drawer = CatalogDrawerModel(
            store: SourceCatalogStore(bundledCatalogURL: bundled, cacheDirectory: cache) { _, _ in throw URLError(.notConnectedToInternet) },
            defaults: try freshDefaults(),
            subscriptions: { (try? repository.loadFeedSubscriptions()) ?? [] },
            follow: { feedURL in
                guard let candidate = try await coordinator.discover(urlString: feedURL).first else { throw FollowedSourceError.noFeedCandidates }
                return try await coordinator.follow(candidate: candidate).source.id
            }
        )
        await drawer.load()
        XCTAssertTrue(drawer.subjects.contains { $0.id == "writers" })
        drawer.selectedSubject = "writers"
        let entry = try XCTUnwrap(drawer.entries.first)
        XCTAssertEqual(entry.contentKind, .newsletter)
        drawer.toggleFollow(entry)
        for _ in 0..<150 where drawer.state(for: entry) != .followed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.state(for: entry), .followed)

        let subscription = try XCTUnwrap(repository.loadFeedSubscriptions().first)
        XCTAssertEqual(subscription.source.kind, .articleFeed)
        XCTAssertEqual(subscription.source.canonicalURL, entry.feedURL)
        XCTAssertEqual(try repository.loadFeedEntries(subscriptionId: subscription.id).map(\.title), ["A first post"])
    }

    func testSubjectFilterAndFailedFollowStayOnTheRow() async throws {
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log)
        await drawer.load()
        let subject = try XCTUnwrap(drawer.subjects.first)
        drawer.selectedSubject = subject.id
        XCTAssertFalse(drawer.entries.isEmpty)
        XCTAssertTrue(drawer.entries.allSatisfy { $0.subjects.contains(subject.id) })

        log.failing = true
        let entry = try XCTUnwrap(drawer.entries.first)
        drawer.toggleFollow(entry)
        for _ in 0..<100 {
            if case .failed = drawer.state(for: entry) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = drawer.state(for: entry) else { return XCTFail("failure shows on the row") }
        log.failing = false
        drawer.toggleFollow(entry) // Retry
        for _ in 0..<100 where drawer.state(for: entry) != .followed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drawer.state(for: entry), .followed)
    }

    func testUpgradedLibraryReachesTheDrawerFromFollowingOnly() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: false, followedSourceCount: 0)
        XCTAssertFalse(drawer.isPresented)
        drawer.present()
        XCTAssertTrue(drawer.isPresented)
    }

    // MARK: Search by name (#471)

    private func searcher(pause: Duration = .milliseconds(10), answer: @escaping @Sendable (URL) throws -> Data) -> PodcastNameSearch {
        PodcastNameSearch(resolver: ITunesSearchSourceResolver { url, _ in (200, try answer(url)) }, pause: pause)
    }

    nonisolated private static func iTunesResponse(_ shows: [(id: Int, title: String, feed: String?)]) -> Data {
        let results = shows.map { show in
            let feed = show.feed.map { #","feedUrl":"\#($0)""# } ?? ""
            return #"{"collectionId":\#(show.id),"collectionName":"\#(show.title)","artistName":"Studio"\#(feed)}"#
        }.joined(separator: ",")
        return Data(#"{"resultCount":\#(shows.count),"results":[\#(results)]}"#.utf8)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testSearchingByNameShowsTheMatchingShowFirstAndOneTapFollowsIt() async throws {
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log, searcher: searcher { _ in
            Self.iTunesResponse([
                (1, "Fork Lore", "https://forklore.example/feed.xml"),
                (2, "Hard Fork", "https://hardfork.example/feed.xml"),
            ])
        })
        await drawer.load()
        drawer.selectedSubject = drawer.subjects.first?.id
        XCTAssertFalse(drawer.showsSearchResults)

        drawer.searchText = "hard fork"
        try await waitFor { drawer.searchResults != nil }
        XCTAssertTrue(drawer.showsSearchResults, "results replace the subject list")
        let top = try XCTUnwrap(drawer.searchResults?.first)
        XCTAssertEqual(top.title, "Hard Fork", "the exact title comes first")

        drawer.followSearchResult(top)
        drawer.followSearchResult(top) // a second tap while following does nothing
        try await waitFor { drawer.state(for: top) == .followed }
        XCTAssertEqual(drawer.state(for: top), .followed)
        XCTAssertEqual(log.feeds, ["https://hardfork.example/feed.xml"], "one subscription")
        XCTAssertEqual(log.subscriptions.count, 1)
    }

    func testAShowWithNoPublicFeedIsListedWithItsReasonAndCannotBeFollowed() async throws {
        let log = FollowLog()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log, searcher: searcher { _ in
            Self.iTunesResponse([(7, "Exclusive Show", nil)])
        })
        await drawer.load()
        drawer.searchText = "exclusive show"
        try await waitFor { drawer.searchResults != nil }
        let show = try XCTUnwrap(drawer.searchResults?.first)
        XCTAssertNil(show.feed)
        XCTAssertEqual(show.reason, "No public feed: this show is exclusive to another app")

        drawer.followSearchResult(show)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.feeds, [], "nothing was followed")
        XCTAssertNil(drawer.state(for: show))
    }

    func testANetworkFailureShowsAMessageAndLeavesTheSubjectListUsable() async throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), searcher: searcher { _ in
            throw URLError(.notConnectedToInternet)
        })
        await drawer.load()
        let subjectEntries = drawer.entries

        drawer.searchText = "hard fork"
        try await waitFor { drawer.searchError != nil }
        XCTAssertEqual(drawer.searchError, PodcastNameSearch.networkFailureMessage)
        XCTAssertNil(drawer.searchResults)
        XCTAssertFalse(drawer.showsSearchResults, "the subject list stays on screen")
        XCTAssertEqual(drawer.entries, subjectEntries)
        XCTAssertFalse(subjectEntries.isEmpty)
    }

    func testClearingTheSearchReturnsToTheSubjectTheListenerWasOn() async throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), searcher: searcher { _ in
            Self.iTunesResponse([(1, "Hard Fork", "https://hardfork.example/feed.xml")])
        })
        await drawer.load()
        let subject = try XCTUnwrap(drawer.subjects.dropFirst().first?.id)
        drawer.selectedSubject = subject
        let entries = drawer.entries

        drawer.searchText = "hard fork"
        try await waitFor { drawer.searchResults != nil }
        XCTAssertTrue(drawer.showsSearchResults)

        drawer.searchText = ""
        XCTAssertFalse(drawer.showsSearchResults)
        XCTAssertNil(drawer.searchResults)
        XCTAssertEqual(drawer.selectedSubject, subject)
        XCTAssertEqual(drawer.entries, entries)
    }

    func testOneCharacterDoesNotSearch() async throws {
        let requests = RequestCount()
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), searcher: searcher { _ in
            requests.add()
            return Self.iTunesResponse([])
        })
        drawer.searchText = "h"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.value, 0)
        XCTAssertFalse(drawer.isSearching)
        XCTAssertFalse(drawer.isSearchPending)
    }

    private final class RequestCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}

/// A Substack-style RSS feed with one text post, served for any URL on the stubbed session.
private final class SubstackFeedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "example.substack.com"
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
        <title>A Writer</title><link>https://\(host)</link><description>Posts</description>
        <item><title>A first post</title><link>https://\(host)/p/a-first-post</link>
        <guid isPermaLink="false">https://\(host)/p/a-first-post</guid>
        <pubDate>Wed, 30 Sep 2026 12:00:00 GMT</pubDate><description>Hello.</description></item>
        </channel></rss>
        """.utf8)
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/rss+xml; charset=utf-8", "Content-Length": "\(data.count)"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
