import XCTest
@testable import SessionKit

/// B1 M1: a fresh install offers at least 100 popular podcasts with artwork, filterable by at
/// least 8 subjects, and works offline from the bundled snapshot.
final class FirstRunCatalogDrawerTests: XCTestCase {
    private static let bundledSnapshot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SessionKitTests
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

    func testDrawerOpensByItselfOnlyOnAFreshInstallAndOnlyOnce() {
        XCTAssertTrue(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: false, followedSourceCount: 0))
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: true, followedSourceCount: 0), "once")
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: false, hasSeenDrawer: false, followedSourceCount: 0), "upgraded Library")
        XCTAssertFalse(FirstRunCatalogDrawerPolicy.opensAutomatically(libraryWasEmptyAtLaunch: true, hasSeenDrawer: false, followedSourceCount: 2), "already following")
    }
}
