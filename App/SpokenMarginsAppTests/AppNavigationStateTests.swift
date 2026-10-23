import XCTest
import SessionKit
@testable import SpokenMarginsApp

final class AppNavigationStateTests: XCTestCase {
    func testEachRootRetainsAnIndependentNavigationPath() {
        var navigation = AppNavigationState()

        navigation.push(.item("library-item"), recordingIsLocked: false)
        navigation.select(.sources, recordingIsLocked: false)
        navigation.push(.item("source-item"), recordingIsLocked: false)
        navigation.select(.margins, recordingIsLocked: false)
        navigation.push(.marginDetail("margin-1"), recordingIsLocked: false)

        XCTAssertEqual(navigation.selectedRoot, .margins)
        XCTAssertEqual(navigation.paths[.library], [.item("library-item")])
        XCTAssertEqual(navigation.paths[.sources], [.item("source-item")])
        XCTAssertEqual(navigation.paths[.margins], [.marginDetail("margin-1")])
    }

    /// #1784: the add sheet's "Search podcasts by name" closes the sheet and asks for the catalog once.
    func testSearchingPodcastsFromTheAddSheetClosesItAndAsksForTheCatalogOnce() {
        var navigation = AppNavigationState()
        navigation.addSourceRoute = .linkOrPodcast

        navigation.searchPodcastsFromAddSheet()

        XCTAssertNil(navigation.addSourceRoute)
        XCTAssertTrue(navigation.takeCatalogRequest())
        XCTAssertFalse(navigation.takeCatalogRequest(), "a later dismissal must not reopen the catalog")
    }

    func testClosingTheAddSheetWithoutSearchingNeverOpensTheCatalog() {
        var navigation = AppNavigationState()
        navigation.addSourceRoute = .linkOrPodcast
        navigation.addSourceRoute = nil
        XCTAssertFalse(navigation.takeCatalogRequest())
    }

    /// #479: the root view holds Following's place across the screen switches that destroy its list.
    func testFollowingKeepsItsPlaceWhileOtherRootsAreUsed() {
        var navigation = AppNavigationState()
        XCTAssertEqual(navigation.followingScroll, FollowingScrollMemory())

        navigation.followingScroll = FollowingScrollMemory(topEntryId: "b", order: ["a", "b", "c"])
        navigation.select(.sources, recordingIsLocked: false)
        navigation.select(.library, recordingIsLocked: false)
        navigation.push(.item("library-item"), recordingIsLocked: false)

        XCTAssertEqual(navigation.followingScroll.restoreTarget(in: ["a", "c"]), "c")
    }

    /// #2395: the Library list keeps its place across opening an item, apart from Following's.
    func testLibraryKeepsItsPlaceAcrossOpeningAnItem() {
        var navigation = AppNavigationState()
        XCTAssertEqual(navigation.libraryScroll, FollowingScrollMemory())

        navigation.libraryScroll = FollowingScrollMemory(topEntryId: "c", order: ["a", "b", "c", "d"])
        navigation.push(.item("c"), recordingIsLocked: false)
        navigation.select(.sources, recordingIsLocked: false)
        navigation.select(.library, recordingIsLocked: false)

        XCTAssertEqual(navigation.libraryScroll.restoreTarget(in: ["a", "b", "c", "d", "e"]), "c")
        XCTAssertEqual(navigation.libraryScroll.restoreTarget(in: ["a", "b", "d"]), "d", "the item just finished or deleted: the next row down")
        XCTAssertNil(navigation.libraryScroll.restoreTarget(in: []))
        XCTAssertEqual(navigation.followingScroll, FollowingScrollMemory(), "Following's place is its own")
    }

    func testExplicitRootPushDoesNotChangeTheSelectedRoot() {
        var navigation = AppNavigationState()
        navigation.select(.sources, recordingIsLocked: false)

        navigation.push(.settings, in: .library, recordingIsLocked: false)

        XCTAssertEqual(navigation.selectedRoot, .sources)
        XCTAssertEqual(navigation.paths[.library], [.settings])
        XCTAssertEqual(navigation.paths[.sources], [])
    }

    func testRecordingLockRejectsRootPathAndTaskMutations() {
        var navigation = AppNavigationState()
        navigation.push(.item("current-item"), recordingIsLocked: false)
        navigation.present(.nowPlaying, recordingIsLocked: false)
        let lockedState = navigation

        navigation.select(.sources, recordingIsLocked: true)
        navigation.push(.item("other-item"), recordingIsLocked: true)
        navigation.push(.marginDetail("other-margin"), in: .margins, recordingIsLocked: true)
        navigation.present(.settings, recordingIsLocked: true)
        navigation.dismissTask(recordingIsLocked: true)

        XCTAssertEqual(navigation, lockedState)
    }

    func testTaskCanBeDismissedAfterRecordingUnlocks() {
        var navigation = AppNavigationState()
        navigation.present(.nowPlaying, recordingIsLocked: false)

        navigation.dismissTask(recordingIsLocked: false)

        XCTAssertNil(navigation.taskRoute)
    }
}
