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
        startFirstListen: (@MainActor ([String], Bool) async -> Void)? = nil,
        libraryHoldsFriendPacket: (@Sendable () async -> Bool)? = nil,
        openFriendLink: (@MainActor (URL) -> Void)? = nil
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
            startFirstListen: startFirstListen,
            libraryHoldsFriendPacket: libraryHoldsFriendPacket,
            openFriendLink: openFriendLink,
            packetOpenFailures: PacketOpenFailurePresenter()
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
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log) { ids, _ in started.append(ids) }
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

    /// #4290: Done on the preview a Shortcut opened closes the whole drawer and plays nothing, on the first-run opening
    /// too (bringing shows in from Apple Podcasts is not a first pick). Cancel only pops back to the drawer's list.
    func testDoneAfterAShortcutImportClosesTheDrawerAndPlaysNothing() async throws {
        var started: [[String]] = []
        let defaults = try freshDefaults()
        let drawer = CatalogDrawerModel(
            store: nil, defaults: defaults, subscriptions: { [] }, follow: { _ in "" },
            makeOPMLImport: { OPMLImportModel(subscriptions: { [] }, follow: { _ in }, didFollow: {}) },
            startFirstListen: { ids, _ in started.append(ids) }
        )
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        XCTAssertTrue(drawer.isPresented)

        // Cancel on the preview: the list closes, the drawer stays.
        XCTAssertTrue(drawer.openShortcutImport(feedLinks: ["Pod One https://feeds.example.com/pod1.xml"]))
        drawer.shortcutImport = nil
        XCTAssertTrue(drawer.isPresented)

        XCTAssertTrue(drawer.openShortcutImport(feedLinks: ["Pod One https://feeds.example.com/pod1.xml"]))
        XCTAssertEqual(drawer.shortcutImport?.origin, .shortcut)
        drawer.finishAfterShortcutImport()
        XCTAssertFalse(drawer.isPresented, "Done closes the whole drawer")
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [], "nothing plays: a Shortcut import is not a pick")
        XCTAssertNil(drawer.shortcutImport)
        XCTAssertTrue(defaults.bool(forKey: CatalogDrawerModel.seenKey), "the first-run opening is spent")
    }

    #if !SPOKEN_MARGINS_LEGACY
    /// #4290: the action's no-links error speaks to a listener who added our Shortcut, in the words the guide's tests pin.
    func testTheShortcutsNoLinksErrorIsTheGuidesWording() {
        XCTAssertEqual(FollowPodcastsShortcutError.noLinks.errorDescription, ApplePodcastsImportShortcut.noLinksMessage)
    }
    #endif

    func testDoneWithNothingFollowedStartsTheFirstListenWithNoPicksSoTheWelcomeSamplePlays() async throws {
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog()) { ids, _ in started.append(ids) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.finish()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [[]])
    }

    func testAFailedFollowIsNotAPickAndASwipeOrAFollowingOpeningDoesNotPlay() async throws {
        let log = FollowLog()
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log) { ids, _ in started.append(ids) }
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
        try await pollUntil { drawer.followedCount >= 5 }
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
        try await pollUntil { drawer.followedCount >= 1 }
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
        try await pollUntil { drawer.followedCount >= 1 }
        XCTAssertEqual(drawer.state(for: entry), .followed)

        drawer.isPresented = false
        drawer.markSeen()
        log.subscriptions.removeAll() // unfollowed in Following
        drawer.present()

        XCTAssertNil(drawer.state(for: entry), "shows Follow again")
        XCTAssertNil(drawer.followStates(for: drawer.entries)[entry.id])
        drawer.toggleFollow(entry)
        try await pollUntil { drawer.followedCount >= 1 }
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
        try await pollUntil { drawer.followedCount >= 1 }
        XCTAssertEqual(drawer.followedSummary, "Following 1 newsletter")

        drawer.selectedSubject = nil
        let show = try XCTUnwrap(drawer.entries.first { $0.contentKind == .podcast })
        drawer.toggleFollow(show)
        try await pollUntil { drawer.followedCount >= 2 }
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
        try await pollUntil { drawer.followedCount >= 1 }
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
        try await pollUntil { drawer.state(for: entry) == .followed }
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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if case .failed = drawer.state(for: entry) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = drawer.state(for: entry) else { return XCTFail("failure shows on the row") }
        log.failing = false
        drawer.toggleFollow(entry) // Retry
        try await pollUntil { drawer.state(for: entry) == .followed }
        XCTAssertEqual(drawer.state(for: entry), .followed)
    }

    /// #3291: a first launch opened from a friend's file opens the friend's item first; the drawer waits for the Library.
    func testAFriendsFileOnAFirstLaunchComesBeforeTheDrawer() throws {
        let defaults = try freshDefaults()
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog())
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.settleFirstRun(at: .library)
        XCTAssertFalse(drawer.isPresented, "the friend's item hasn't opened yet")
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        XCTAssertFalse(drawer.isPresented)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented, "back on the Library after the friend's item")
        drawer.isPresented = false
        drawer.didDismiss()
        XCTAssertFalse(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey))
    }

    func testAFileHandedOverBeforeTheRootViewAppearsStillComesFirst() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        drawer.friendFileArrived()
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.settleFirstRun(at: .library)
        XCTAssertFalse(drawer.isPresented)
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented)
    }

    func testAFriendsFileWithdrawsAnUntouchedDrawerWithoutMarkingItSeen() async throws {
        let defaults = try freshDefaults()
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog()) { ids, _ in started.append(ids) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        XCTAssertTrue(drawer.isPresented)
        drawer.friendFileArrived()
        XCTAssertFalse(drawer.isPresented)
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [], "the Welcome article waits too")
        XCTAssertFalse(defaults.bool(forKey: CatalogDrawerModel.seenKey))

        // The friend's item never opened in this launch: the next launch still owes the drawer, Library or not.
        let next = try makeDrawer(defaults: defaults, log: FollowLog())
        next.presentIfFirstRun(libraryWasEmptyAtLaunch: false, followedSourceCount: 0)
        XCTAssertTrue(next.isPresented)
    }

    /// #3796: back on the Library after the friend's item, Done with nothing picked plays nothing, and no Terms follow.
    func testDoneWithNothingPickedAfterAFriendsItemPlaysNothing() async throws {
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog()) { ids, _ in started.append(ids) }
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.settleFirstRun(at: .library)
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented)
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [], "the Welcome sample stays in the Library for a tap")
    }

    /// #3796: a pick still plays in a held-back launch, and the Welcome sample may not stand in for it.
    func testAPickAfterAFriendsItemStillPlaysButTheWelcomeSampleMayNotStandIn() async throws {
        var started: [([String], Bool)] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog()) { ids, welcome in started.append((ids, welcome)) }
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.settleFirstRun(at: .library)
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .library)
        await drawer.load()
        drawer.toggleFollow(try XCTUnwrap(drawer.entries.first))
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.0, ["source-1"])
        XCTAssertEqual(started.first?.1, false)
    }

    /// #3795: the held-back drawer is owed once. A kill with it up does not bring it back on the next launch.
    func testAHeldBackDrawerIsSpentWhenItOpensSoAKillDoesNotBringItBack() throws {
        let defaults = try freshDefaults()
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog())
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        XCTAssertTrue(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey), "owed to the next launch while held back")
        drawer.settleFirstRun(at: .library)
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented)
        XCTAssertFalse(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey), "spent as the drawer opens")

        // The app is killed with the drawer up: no didDismiss. The next launch has the friend's item in the Library.
        let next = try makeDrawer(defaults: defaults, log: FollowLog())
        next.presentIfFirstRun(libraryWasEmptyAtLaunch: false, followedSourceCount: 0)
        XCTAssertFalse(next.isPresented)
    }

    /// #3795: a friend's file that arrives while the drawer is up still owes the drawer after that friend's item.
    func testAFriendsFileWhileTheHeldBackDrawerIsUpOwesItAgain() throws {
        let defaults = try freshDefaults()
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog())
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.settleFirstRun(at: .library)
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented)
        drawer.friendFileArrived()
        XCTAssertFalse(drawer.isPresented, "withdrawn for the second friend's file")
        XCTAssertTrue(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey))
        drawer.didDismiss()
        drawer.packetOpenFailures?.friendItemOpened(itemId: "friend-item")
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented, "back after the second friend's item")
    }

    /// #3801: a friend's link that failed on a first launch leaves no empty Library: the drawer it withdrew is back
    /// once the failure sheet closes, and Done with nothing picked plays the Welcome sample as on any first launch.
    func testAFailedFriendFileBringsTheDrawerBackOnTheLibraryAndDonePlaysTheWelcomeSample() async throws {
        let defaults = try freshDefaults()
        var started: [(ids: [String], allowsWelcome: Bool)] = []
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog()) { ids, allowsWelcome in started.append((ids, allowsWelcome)) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        XCTAssertFalse(drawer.isPresented, "withdrawn for the friend's file")
        drawer.didDismiss()
        XCTAssertTrue(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey))

        drawer.friendFileFailed(at: .library)

        XCTAssertTrue(drawer.isPresented, "the Library is not left empty")
        XCTAssertFalse(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey), "spent as the drawer opens")
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started.map(\.allowsWelcome), [true], "no friend's item is in the Library, so the Welcome sample may play")
    }

    /// #3801: a failure that closes while the listener is elsewhere owes the drawer for the next visit to the Library.
    func testAFailedFriendFileClosedElsewhereBringsTheDrawerBackAtTheNextLibraryVisit() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.didDismiss()

        drawer.friendFileFailed(at: .elsewhere)
        XCTAssertFalse(drawer.isPresented)
        drawer.listenerMoved(to: .library)
        XCTAssertTrue(drawer.isPresented)
    }

    /// The audit on PR #4597: a failure closed away from the Library, then a kill before the Library, owes the drawer to
    /// the next launch without holding it back, so Done with nothing picked there plays the Welcome sample.
    func testAFailedFriendFileClosedElsewhereThenAKillOwesTheNextLaunchADrawerThatPlaysTheWelcomeSample() async throws {
        let defaults = try freshDefaults()
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog())
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.settleFirstRun(at: .elsewhere)
        drawer.friendFileArrived()
        drawer.friendFileFailed(at: .elsewhere)
        XCTAssertFalse(drawer.isPresented)
        XCTAssertFalse(defaults.bool(forKey: CatalogDrawerModel.deferredByFriendFileKey), "no friend's item came of it")
        XCTAssertTrue(defaults.bool(forKey: CatalogDrawerModel.owedAfterFriendFileFailedKey))

        // Killed before the Library. The next launch has the Welcome sample in the Library, so it is not empty.
        var started: [(ids: [String], allowsWelcome: Bool)] = []
        let next = try makeDrawer(defaults: defaults, log: FollowLog()) { ids, allowsWelcome in started.append((ids, allowsWelcome)) }
        next.presentIfFirstRun(libraryWasEmptyAtLaunch: false, followedSourceCount: 0)
        XCTAssertTrue(next.isPresented, "still owed")
        XCTAssertFalse(defaults.bool(forKey: CatalogDrawerModel.owedAfterFriendFileFailedKey), "spent as the drawer opens")
        next.finish()
        next.didDismiss()
        await next.playFirstListenIfRequested()
        XCTAssertEqual(started.map(\.allowsWelcome), [true], "no friend's item is in the Library, so the Welcome sample may play")
    }

    /// #3801: a failure that lands before the root view has noted the launch is not replayed as an arrival.
    func testAFriendFileThatFailedBeforeTheRootViewAppearedDoesNotHoldTheDrawerBack() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        drawer.friendFileArrived()
        drawer.friendFileFailed(at: .library)
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.settleFirstRun(at: .library)
        XCTAssertTrue(drawer.isPresented, "nothing is waiting on a friend's item")
    }

    /// #3801: a failure with no drawer withdrawn (it was not owed, or the listener has picks) changes nothing.
    func testAFailedFriendFileWithNoDrawerOwedChangesNothing() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        drawer.noteLaunch(libraryWasEmptyAtLaunch: false, followedSourceCount: 3)
        drawer.settleFirstRun(at: .library)
        drawer.friendFileFailed(at: .library)
        XCTAssertFalse(drawer.isPresented)
    }

    /// #4834: an item the listener opened themselves while a friend's link waited is not the friend's item, so that link
    /// failing still brings the drawer back and Done plays the Welcome sample.
    func testAFailedFriendLinkAfterTheListenerOpenedTheirOwnItemBringsTheDrawerBackAndDonePlays() async throws {
        var started: [(ids: [String], allowsWelcome: Bool)] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog()) { ids, allowsWelcome in started.append((ids, allowsWelcome)) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.didDismiss()
        drawer.listenerMoved(to: .item)
        drawer.listenerMoved(to: .elsewhere)

        drawer.friendFileFailed(at: .elsewhere)
        drawer.listenerMoved(to: .library)

        XCTAssertTrue(drawer.isPresented)
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started.map(\.allowsWelcome), [true])
    }

    /// #4672 PR 3: the item a friend's file opened on a first launch is remembered as the arrival item, once; an
    /// item opened with no friend's file waiting, or a second friend's item, never replaces it.
    func testOnlyTheFirstFriendItemOfAFirstLaunchIsRememberedAsTheArrivalItem() throws {
        let defaults = try freshDefaults()
        let drawer = try makeDrawer(defaults: defaults, log: FollowLog())
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.didDismiss()
        drawer.friendItemOpened("friend-episode")
        drawer.friendItemOpened("second-friend-item")
        XCTAssertEqual(FirstLaunchArrival(defaults: defaults).itemId, "friend-episode")

        // A friend's link that arrives while the first-run drawer still shows picks opens its item underneath it.
        let underPicks = try freshDefaults()
        let picking = try makeDrawer(defaults: underPicks, log: FollowLog())
        picking.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        picking.friendFileArrived()
        picking.friendItemOpened("pasted-link-episode")
        XCTAssertEqual(FirstLaunchArrival(defaults: underPicks).itemId, "pasted-link-episode")

        let returning = try freshDefaults()
        let notFirstLaunch = try makeDrawer(defaults: returning, log: FollowLog())
        notFirstLaunch.friendItemOpened("friend-episode")
        XCTAssertNil(FirstLaunchArrival(defaults: returning).itemId, "no first-launch drawer was owed, so this is not an arrival")
    }

    /// #4834: the drawer comes back only once the failure sheet has fully left (its `onDismiss`), never on the close that
    /// starts it: a sheet presented while the old one is still dismissing is dropped by SwiftUI. A Try Again that is
    /// refused, and a banner after the sheet closed, are told the same way.
    func testTheFailedLinkNoticeReachesTheDrawerOnlyAfterTheSheetHasLeft() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        let presenter = try XCTUnwrap(drawer.packetOpenFailures)
        presenter.onCloseNotice = { [weak drawer] in drawer?.friendFileFailed(at: .library) }
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.settleFirstRun(at: .library)
        XCTAssertFalse(drawer.isPresented)

        presenter.present(PacketOpenFailureSheetContent(row: .offline), retry: {}, endsOpen: true)
        presenter.close()
        XCTAssertFalse(drawer.isPresented, "the sheet is still leaving")

        presenter.sheetDismissed()
        XCTAssertTrue(drawer.isPresented, "the sheet is gone: the drawer comes back")
    }

    func testARefusedFileAfterTryAgainTellsTheDrawerOnceTheSheetHasLeft() throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog())
        let presenter = try XCTUnwrap(drawer.packetOpenFailures)
        presenter.onCloseNotice = { [weak drawer] in drawer?.friendFileFailed(at: .library) }
        drawer.noteLaunch(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        drawer.friendFileArrived()
        drawer.settleFirstRun(at: .library)

        presenter.present(PacketOpenFailureSheetContent(row: .offline), retry: {}, endsOpen: true)
        presenter.tryAgain()
        let since = presenter.openToken
        presenter.present(PacketOpenFailureSheetContent(row: .expired), retry: nil)
        presenter.close()
        presenter.sheetDismissed()
        XCTAssertFalse(drawer.isPresented, "the refused file's open has not ended yet")

        presenter.openEnded(opened: false, since: since)
        XCTAssertTrue(drawer.isPresented, "the open ended with nothing to show: the drawer comes back")
    }

    // MARK: The first-launch "Got a link from a friend?" card (#3782)

    private var friendLink: String { "https://\(ShareLinkURL.shareHosts[0])/l/\(String(repeating: "ab12", count: 8))#\(ShareLinkSealing.Key.random().fragment)" }

    /// The card shows on the first-launch opening while the Library holds no friend's packet, never on a later visit.
    func testTheCardShowsOnTheFirstLaunchOpeningOnlyWhileTheLibraryHoldsNoFriendsPacket() async throws {
        let empty = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { false })
        XCTAssertFalse(empty.showsFriendLinkCard)
        empty.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        try await pollUntil(timeout: .seconds(30)) { empty.showsFriendLinkCard }
        XCTAssertTrue(empty.showsFriendLinkCard)

        let holding = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { true })
        holding.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        try await pollUntil(timeout: .milliseconds(300)) { holding.showsFriendLinkCard }
        XCTAssertFalse(holding.showsFriendLinkCard, "a packet is already in the Library")

        let later = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { false })
        later.present()
        try await pollUntil(timeout: .milliseconds(300)) { later.showsFriendLinkCard }
        XCTAssertFalse(later.showsFriendLinkCard, "opened from Following, not the first-launch opening")
    }

    /// A friend's file arriving while the card shows takes it away.
    func testAFriendsFileArrivingHidesTheCard() async throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { false })
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        try await pollUntil { drawer.showsFriendLinkCard }
        drawer.friendFileArrived()
        XCTAssertFalse(drawer.showsFriendLinkCard)
    }

    /// Paste of a share link: told to the first-launch order as a friend's file (an untouched drawer withdraws), then opened.
    func testPastingAShareLinkWithdrawsTheUntouchedDrawerAndOpensTheLink() async throws {
        var opened: [URL] = []
        let drawer = try makeDrawer(
            defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { false }, openFriendLink: { opened.append($0) })
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        try await pollUntil { drawer.showsFriendLinkCard }
        let link = friendLink

        drawer.pasteIntoFriendLinkCard("Sam sent you Margins: \(link)")

        XCTAssertEqual(opened, [URL(string: link)!])
        XCTAssertFalse(drawer.isPresented, "withdrawn so the friend's item comes first")
        XCTAssertNil(drawer.friendLinkNote)
    }

    /// Paste of a link when the drawer has picks: the sheet stays and Done plays nothing over the friend's item.
    func testPastingAShareLinkIntoADrawerWithPicksLeavesTheSheetUp() async throws {
        var opened: [URL] = []
        var started: [[String]] = []
        let drawer = try makeDrawer(
            defaults: try freshDefaults(), log: FollowLog(), startFirstListen: { ids, _ in started.append(ids) },
            libraryHoldsFriendPacket: { false }, openFriendLink: { opened.append($0) })
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        await drawer.load()
        drawer.toggleFollow(try XCTUnwrap(drawer.entries.first))

        drawer.pasteIntoFriendLinkCard(friendLink)

        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(drawer.isPresented, "the listener is choosing")
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [])
    }

    /// Paste of anything else (the join page, an article, nothing): the sheet stays, nothing opens, one line says why.
    func testPastingSomethingElseOpensNothingAndLeavesALineUntilTheNextPaste() async throws {
        var opened: [URL] = []
        let drawer = try makeDrawer(
            defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { false }, openFriendLink: { opened.append($0) })
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        try await pollUntil { drawer.showsFriendLinkCard }

        for pasted: String? in ["https://spokenmargins.com/join", "https://example.com/article", nil] {
            drawer.pasteIntoFriendLinkCard(pasted)
            XCTAssertEqual(drawer.friendLinkNote, FirstLaunchFriendLinkCard.notAFriendLinkLine)
            XCTAssertTrue(drawer.isPresented)
        }
        XCTAssertEqual(opened, [])

        drawer.pasteIntoFriendLinkCard(friendLink)
        XCTAssertNil(drawer.friendLinkNote, "the next paste clears the line")
        XCTAssertEqual(opened.count, 1)
    }

    /// #3801 meets this card: a pasted link that fails brings the withdrawn drawer back, with the card.
    func testAPastedLinkThatFailsBringsTheDrawerAndTheCardBack() async throws {
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: FollowLog(), libraryHoldsFriendPacket: { false })
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        try await pollUntil { drawer.showsFriendLinkCard }
        drawer.pasteIntoFriendLinkCard(friendLink)
        drawer.didDismiss()

        drawer.friendFileFailed(at: .library)

        XCTAssertTrue(drawer.isPresented)
        try await pollUntil { drawer.showsFriendLinkCard }
        XCTAssertTrue(drawer.showsFriendLinkCard)
    }

    /// A pasted link that fails while the drawer has picks (it never withdrew): the card returns for another paste, and
    /// Done plays the pick again because no friend's item arrived.
    func testAPastedLinkThatFailsOverADrawerWithPicksBringsTheCardBackAndDonePlaysAgain() async throws {
        var started: [[String]] = []
        let drawer = try makeDrawer(
            defaults: try freshDefaults(), log: FollowLog(), startFirstListen: { ids, _ in started.append(ids) },
            libraryHoldsFriendPacket: { false })
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        await drawer.load()
        try await pollUntil { drawer.showsFriendLinkCard }
        drawer.toggleFollow(try XCTUnwrap(drawer.entries.first))
        drawer.pasteIntoFriendLinkCard(friendLink)
        XCTAssertFalse(drawer.showsFriendLinkCard)
        XCTAssertTrue(drawer.isPresented, "the listener has a pick, so the sheet stays")

        drawer.friendFileFailed(at: .library)

        try await pollUntil { drawer.showsFriendLinkCard }
        XCTAssertTrue(drawer.showsFriendLinkCard, "another paste is possible")
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started.count, 1, "no friend's item arrived, so Done plays the pick")
    }

    func testADrawerWithPicksStaysButDonePlaysNothingOverTheFriendsItem() async throws {
        let log = FollowLog()
        var started: [[String]] = []
        let drawer = try makeDrawer(defaults: try freshDefaults(), log: log) { ids, _ in started.append(ids) }
        drawer.presentIfFirstRun(libraryWasEmptyAtLaunch: true, followedSourceCount: 0)
        await drawer.load()
        drawer.toggleFollow(try XCTUnwrap(drawer.entries.first))
        drawer.friendFileArrived()
        XCTAssertTrue(drawer.isPresented, "the listener is choosing")
        drawer.finish()
        drawer.didDismiss()
        await drawer.playFirstListenIfRequested()
        XCTAssertEqual(started, [])
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
        try await pollUntil { condition() }
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
            Self.iTunesResponse([(7, "Exclusive Show", nil), (8, "Open Show", "https://open.example/feed.xml")])
        })
        await drawer.load()
        drawer.searchText = "exclusive show"
        try await waitFor { drawer.searchResults != nil }
        let show = try XCTUnwrap(drawer.searchResults?.first)
        XCTAssertNil(show.feed)
        XCTAssertEqual(show.reason, "No public feed: this show is exclusive to another app")
        let open = try XCTUnwrap(drawer.searchResults?.last)

        drawer.followSearchResult(show)
        XCTAssertNil(drawer.state(for: show))
        // A later follow on the same main actor: once it has landed, a follow the first tap wrongly started would have
        // run too. A fixed 100 ms passed for a follow slower than that (#4313).
        drawer.followSearchResult(open)
        try await waitFor { drawer.state(for: open) == .followed }
        XCTAssertEqual(log.feeds, ["https://open.example/feed.xml"], "only the show with a feed was followed")
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
        // No wait (#4313): the drawer turns one character away before any search task exists, so a search that started
        // shows at once as isSearchPending, which carries this test; the request count only says none went out yet.
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
