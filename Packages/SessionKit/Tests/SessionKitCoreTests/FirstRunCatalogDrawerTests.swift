import XCTest
@testable import SessionKit

/// B1 M1: a fresh install offers at least 100 popular podcasts with artwork, filterable by at
/// least 8 subjects, and works offline from the bundled snapshot.
final class FirstRunCatalogDrawerTests: XCTestCase {
    private static let bundledSnapshot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SessionKitCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // SessionKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo
        .appending(path: "Site/onboarding/catalog/v1/catalog.json")

    func testBundledSnapshotOffersAHundredPodcastsWithArtworkAcrossEightSubjects() throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: Self.bundledSnapshot))
        let followable = catalog.entries(forSubject: nil)
        XCTAssertGreaterThanOrEqual(followable.count, 100)
        XCTAssertTrue(followable.allSatisfy { $0.artworkURL?.hasPrefix("https://") == true }, "every entry shows artwork")
        XCTAssertTrue(followable.allSatisfy { $0.feedURL.hasPrefix("https://") })
        let subjects = catalog.visibleSubjects
        XCTAssertGreaterThanOrEqual(subjects.count, 8)
        for subject in subjects {
            XCTAssertFalse(catalog.entries(forSubject: subject.id).isEmpty, subject.id)
        }
    }

    /// #470: a short hand-picked "Writers" row of Substack publications, followed as article feeds.
    func testWritersSubjectOffersExactlyItsHandPickedStarterRowOfNewsletters() throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: Self.bundledSnapshot))
        XCTAssertTrue(catalog.visibleSubjects.contains { $0.id == "writers" && $0.title == "Writers" })
        let starterRow = try XCTUnwrap(catalog.starterRows?.first { $0.subjectId == "writers" })
        let writers = catalog.entries(forSubject: "writers")
        XCTAssertEqual(writers.map(\.id), starterRow.entryIds)
        XCTAssertTrue((6...10).contains(writers.count), "keep it short: \(writers.count)")
        for entry in writers {
            XCTAssertEqual(entry.kind, .articleFeed, entry.id)
            XCTAssertEqual(entry.kind.identityKind, .articleFeed, entry.id)
            XCTAssertEqual(entry.contentKind, .newsletter, entry.id)
            XCTAssertTrue(entry.feedURL.hasPrefix("https://") && entry.feedURL.hasSuffix("/feed"), entry.feedURL)
        }
        XCTAssertFalse(catalog.entries(forSubject: "news").contains { $0.contentKind == .newsletter }, "podcast subjects are unchanged")
    }

    /// #224 lane: after a relaunch, a show whose feed settled on another URL once followed showed
    /// "Follow" again in the drawer although Following listed it.
    func testAShowWhoseFeedMovedStaysFollowedAfterARelaunch() throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: Self.bundledSnapshot))
        let entry = try XCTUnwrap(catalog.entries(forSubject: nil).first)
        let moved = FeedSubscription(
            id: "subscription-moved",
            source: SourceIdentity(id: "source-moved", kind: .podcastFeed, canonicalURL: "https://feeds.example.net/moved/feed.xml", host: "feeds.example.net")
        )
        XCTAssertNil(catalog.entry(matchingFeedURL: moved.source.canonicalURL), "URL matching can't find it")
        XCTAssertTrue(CatalogFollowState.isFollowed(entry, in: catalog, recordedSourceId: "source-moved", subscriptions: [moved]))
        XCTAssertFalse(CatalogFollowState.isFollowed(entry, in: catalog, recordedSourceId: "source-moved", subscriptions: []),
                       "unfollowed since: shows Follow again")

        let direct = FeedSubscription(
            id: "subscription-direct",
            source: SourceIdentity(id: "source-direct", kind: .podcastFeed, canonicalURL: entry.feedURL, host: "example")
        )
        XCTAssertTrue(CatalogFollowState.isFollowed(entry, in: catalog, recordedSourceId: nil, subscriptions: [direct]),
                      "a show followed another way still matches by feed URL")
    }

    /// #246: the drawer works out every row's follow state in one pass. It must agree with the
    /// per-row answer for each entry: recorded follows, URL matches, and a recorded follow that
    /// was since unfollowed.
    func testOnePassFollowedIdsMatchThePerRowAnswer() throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: Self.bundledSnapshot))
        let entries = catalog.entries(forSubject: nil)
        XCTAssertGreaterThanOrEqual(entries.count, 6)
        let moved = FeedSubscription(
            id: "subscription-moved",
            source: SourceIdentity(id: "source-moved", kind: .podcastFeed, canonicalURL: "https://feeds.example.net/moved/feed.xml", host: "feeds.example.net")
        )
        // Same feed, different spelling: upper-case host, http, trailing slash.
        var spelled = try XCTUnwrap(URLComponents(string: entries[1].feedURL))
        spelled.scheme = "http"
        spelled.host = spelled.host?.uppercased()
        spelled.path += "/"
        let direct = FeedSubscription(
            id: "subscription-direct",
            source: SourceIdentity(id: "source-direct", kind: .podcastFeed, canonicalURL: try XCTUnwrap(spelled.string), host: "example")
        )
        let elsewhere = FeedSubscription(
            id: "subscription-elsewhere",
            source: SourceIdentity(id: "source-elsewhere", kind: .podcastFeed, canonicalURL: "https://feeds.example.org/not-in-catalog.xml", host: "feeds.example.org")
        )
        let subscriptions = [moved, direct, elsewhere]
        let recorded = [entries[0].id: "source-moved", entries[2].id: "source-unfollowed-since"]

        let followed = CatalogFollowState.followedEntryIds(in: catalog, recordedSourceIds: recorded, subscriptions: subscriptions)

        XCTAssertEqual(followed, [entries[0].id, entries[1].id])
        for entry in catalog.entries {
            XCTAssertEqual(
                followed.contains(entry.id),
                CatalogFollowState.isFollowed(entry, in: catalog, recordedSourceId: recorded[entry.id], subscriptions: subscriptions),
                entry.id
            )
        }
        XCTAssertTrue(CatalogFollowState.followedEntryIds(in: catalog, recordedSourceIds: recorded, subscriptions: []).isEmpty)
    }

    /// #646: follow a show in the drawer, unfollow it in Following, and open the drawer again in
    /// the same app run. The row said Following and refused a second tap, because the drawer's
    /// remembered success outranked the live subscriptions.
    func testAShowUnfollowedSinceTheDrawerFollowedItCanBeFollowedAgainAfterReopening() {
        typealias State = CatalogDrawerFollowState
        let rows = ["unfollowed", "following", "failed", "elsewhere"]
        var drawer: [String: State] = ["unfollowed": .followed, "following": .following, "failed": .failed("Timed out")]

        // While the drawer stays open, a show it just followed reads Following even before the
        // subscription list has caught up.
        XCTAssertEqual(State.merged(drawerStates: drawer, liveFollowedEntryIds: [], entryIds: rows)["unfollowed"], .followed)

        // Unfollowed in Following; only "elsewhere" is still subscribed. Then the drawer opens again.
        drawer = State.keptOnReopening(drawer)
        let reopened = State.merged(drawerStates: drawer, liveFollowedEntryIds: ["elsewhere"], entryIds: rows)

        XCTAssertNil(reopened["unfollowed"], "shows Follow again, so a tap can follow it again")
        XCTAssertEqual(reopened["following"], .following, "a follow in flight still blocks a second tap")
        XCTAssertEqual(reopened["failed"], .failed("Timed out"), "a failure stays on its row")
        XCTAssertEqual(reopened["elsewhere"], .followed)

        // Followed again: the live subscription shows it as followed after the next reopening too.
        drawer["unfollowed"] = .followed
        drawer = State.keptOnReopening(drawer)
        XCTAssertEqual(State.merged(drawerStates: drawer, liveFollowedEntryIds: ["unfollowed"], entryIds: rows)["unfollowed"], .followed)
    }

    func testDrawerOpensByItselfOnlyOnAFreshInstallAndOnlyOnce() {
        XCTAssertTrue(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: false, followedSourceCount: 0))
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: true, followedSourceCount: 0), "once")
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: false, hasSeenDrawer: false, followedSourceCount: 0), "upgraded Library")
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: false, followedSourceCount: 2), "already following")
    }
}
