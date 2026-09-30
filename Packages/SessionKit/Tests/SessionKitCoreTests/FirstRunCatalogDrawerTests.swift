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

    func testDrawerOpensByItselfOnlyOnAFreshInstallAndOnlyOnce() {
        XCTAssertTrue(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: false, followedSourceCount: 0))
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: true, followedSourceCount: 0), "once")
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: false, hasSeenDrawer: false, followedSourceCount: 0), "upgraded Library")
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: false, followedSourceCount: 2), "already following")
    }
}
