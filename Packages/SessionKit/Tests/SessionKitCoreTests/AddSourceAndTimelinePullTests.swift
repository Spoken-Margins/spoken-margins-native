import Foundation
import SessionKit
import XCTest

/// The Add sheet's grid and the Timeline pull, moved from the app-hosted tests (#318): both are plain values.
final class AddSourceAndTimelinePullTests: XCTestCase {
    func testTimelinePullRequiresDeliberateBottomOverscroll() {
        XCTAssertEqual(
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: 540,
                contentHeight: 1_200,
                containerHeight: 640,
                bottomInset: 0
            ),
            0
        )
        XCTAssertEqual(
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: 650,
                contentHeight: 1_200,
                containerHeight: 640,
                bottomInset: 0
            ),
            90
        )
        XCTAssertEqual(
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: 0,
                contentHeight: 500,
                containerHeight: 640,
                bottomInset: 0
            ),
            0,
            "Unused viewport space is not overscroll"
        )
        XCTAssertFalse(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: 71))
        XCTAssertTrue(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: 72))
    }

    func testTimelinePullMeasuresShortContentFromItsInsetRestingPosition() {
        // A short player rests above zero because navigation owns the top inset.
        // The fixed dock also reserves space at the bottom of the scroll view.
        func distance(_ offset: CGFloat) -> CGFloat {
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: offset, contentHeight: 280,
                containerHeight: 874, bottomInset: 342, topInset: 116
            )
        }
        XCTAssertEqual(distance(-116), 0, "Resting short content must not open Timeline")
        XCTAssertEqual(distance(-45), 71)
        XCTAssertFalse(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: distance(-45)))
        XCTAssertEqual(distance(-44), 72)
        XCTAssertTrue(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: distance(-44)))
        XCTAssertEqual(TimelinePullPresentation.overscrollDistance(
            contentOffsetY: 700, contentHeight: 1_200,
            containerHeight: 874, bottomInset: 342, topInset: 116
        ), 32, "Long content must still reach its real bottom before the pull counts")
    }

    // #4816: scrolling to the bottom of Now never changes the tab; only a finger still pulling past the bottom does.
    func testTimelinePullOpensOnlyWhileTheFingerIsStillDragging() {
        var pull = TimelinePullTracker()
        XCTAssertFalse(pull.overscrollChanged(0))
        pull.dragChanged(isDragging: true)
        XCTAssertFalse(pull.overscrollChanged(40), "Short of the activation distance")
        XCTAssertTrue(pull.overscrollChanged(80))
        XCTAssertFalse(pull.overscrollChanged(120), "One pull opens Timeline once")
    }

    func testScrollingToTheBottomOfNowDoesNotOpenTimeline() {
        // (a) A fling that reaches the bottom and rubber-bands past it: the finger is up, the scroll is coasting.
        var fling = TimelinePullTracker()
        fling.dragChanged(isDragging: true)
        XCTAssertFalse(fling.overscrollChanged(0))
        fling.dragChanged(isDragging: false)
        XCTAssertFalse(fling.overscrollChanged(90), "A coasting bounce is not a pull")
        XCTAssertFalse(fling.overscrollChanged(0))

        // (b) The next scene is shorter, so the old offset sits past the new bottom for a moment, with no finger down.
        var sceneAdvance = TimelinePullTracker()
        XCTAssertFalse(sceneAdvance.overscrollChanged(300), "A scene change is not a pull")

        // (c) Back on Now with the previous overscroll still on record, a new touch alone does not open Timeline,
        // and neither does a drag that started inside leftover overscroll.
        var leftover = TimelinePullTracker()
        XCTAssertFalse(leftover.overscrollChanged(300))
        leftover.dragChanged(isDragging: true)
        XCTAssertFalse(leftover.overscrollChanged(310), "The drag did not begin at rest at the bottom")

        // (d) The next scene is shorter while the listener's thumb rests on the text: rest to far past the bottom in
        // one step, with the finger down.
        var restingThumb = TimelinePullTracker()
        restingThumb.dragChanged(isDragging: true)
        XCTAssertFalse(restingThumb.overscrollChanged(0))
        XCTAssertFalse(restingThumb.overscrollChanged(300), "Content changing under a resting finger is not a pull")
        XCTAssertFalse(restingThumb.overscrollChanged(310))
    }

    func testTimelinePullNeedsANewDragAfterItOpened() {
        var pull = TimelinePullTracker()
        pull.dragChanged(isDragging: true)
        XCTAssertFalse(pull.overscrollChanged(30))
        XCTAssertTrue(pull.overscrollChanged(90))
        XCTAssertFalse(pull.overscrollChanged(95))
        _ = pull.overscrollChanged(0)
        XCTAssertFalse(pull.overscrollChanged(30))
        XCTAssertTrue(pull.overscrollChanged(90), "Back at rest and pulling again, in the same drag, is a new pull")
        pull.dragChanged(isDragging: false)
        XCTAssertFalse(pull.overscrollChanged(0))
        pull.dragChanged(isDragging: true)
        XCTAssertFalse(pull.overscrollChanged(20))
        XCTAssertTrue(pull.overscrollChanged(80))
    }

    /// #3217: every way in is one tile in the grid, no two do the same thing, and Files is a single tile.
    func testAddSourceGridHoldsEveryWayInOnceWithOneFilesTile() {
        XCTAssertEqual(
            AddSourcePresentation.tiles,
            [.linkOrPodcast, .findPodcast, .pastedText, .importFromFiles, .quickFolder, .liveSession, .spokenNote]
        )
        XCTAssertEqual(Set(AddSourcePresentation.tiles.map(\.title)).count, AddSourcePresentation.tiles.count, "two tiles share a name")
        let filesTiles = AddSourcePresentation.tiles.filter { $0.route == .importFromFiles }
        XCTAssertEqual(filesTiles, [.importFromFiles])
        XCTAssertEqual(AddSourceTile.importFromFiles.title, "Import from Files")
        // Spoken Note (#3108) sits in a slim row under the grid, so the six grid tiles still end on a full row.
        XCTAssertEqual(AddSourcePresentation.tiles.filter { $0 != .spokenNote }.count % 2, 0, "the two-column grid should end on a full row")
        XCTAssertEqual(AddSourceTile.spokenNote.title, "Spoken Note")
        XCTAssertNil(AddSourceTile.spokenNote.route, "the tile opens the recorder, not a page in the sheet")
    }

    func testFindPodcastTileIsLeftOutWhereTheCatalogCannotOpen() {
        XCTAssertFalse(AddSourcePresentation.tiles(canSearchPodcasts: false).contains(.findPodcast))
        XCTAssertEqual(AddSourcePresentation.tiles(canSearchPodcasts: true), AddSourcePresentation.tiles)
    }

    func testTimelineProvenanceGivesEveryKindALabelAndAnIcon() {
        for kind in TimelineProvenance.allCases {
            XCTAssertFalse(kind.label.isEmpty, "\(kind) has no label")
            XCTAssertFalse(kind.systemImage.isEmpty, "\(kind) has no icon")
        }
        XCTAssertEqual(Set(TimelineProvenance.allCases.map(\.label)).count, TimelineProvenance.allCases.count, "two kinds share a label")
        XCTAssertEqual(TimelineProvenance.sharedMargin.label, "Shared Margin")
        XCTAssertEqual(TimelineProvenance.myMargin.label, "My Margin")
    }

    /// Every tile has words, an icon and, where it opens a page in the sheet, that page's own title.
    func testEveryAddSourceTileHasWordsAndAnIcon() {
        for tile in AddSourceTile.allCases {
            XCTAssertFalse(tile.title.isEmpty, "\(tile) has no title")
            XCTAssertFalse(tile.detail.isEmpty, "\(tile) has no detail")
            XCTAssertFalse(tile.systemImage.isEmpty, "\(tile) has no icon")
            if let route = tile.route {
                XCTAssertEqual(tile.title, route.title, "\(tile) and its page name differ")
                XCTAssertEqual(tile.systemImage, route.systemImage)
            }
        }
        XCTAssertEqual(Set(AddSourcePresentation.tiles), Set(AddSourceTile.allCases), "a tile is not in the grid")
    }
}
