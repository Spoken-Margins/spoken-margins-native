import XCTest
@testable import SessionKit
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
    }

    private func makeDrawer(defaults: UserDefaults, log: FollowLog) throws -> CatalogDrawerModel {
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
            subscriptions: { log.subscriptions },
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
            }
        )
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "CatalogDrawerTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
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
}
