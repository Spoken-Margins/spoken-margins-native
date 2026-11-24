import XCTest
@testable import SessionKit

final class PlaybackLeadingControlTests: XCTestCase {
    func testTimelineLeavesTheScreenLikeMargins() {
        // #4027: Timeline showed an arrow that went back to Now, while Margins left the screen.
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .timeline, timelineEditorHasFocus: false), .libraryExit)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .margins, timelineEditorHasFocus: false), .libraryExit)
    }

    func testEveryTabWithAToolbarArrowLeavesExceptTheEditorCase() {
        for pane in [PlaybackLeadingControl.Pane.timeline, .margins] {
            XCTAssertNotEqual(PlaybackLeadingControl.control(pane: pane, timelineEditorHasFocus: false), .returnToNow,
                              "\(pane) must not use the top-left arrow to switch tabs")
        }
    }

    func testTheTimelineEditorKeepsAWayBackToNowWhileTheTabSwitchIsHidden() {
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .timeline, timelineEditorHasFocus: true), .returnToNow)
    }

    func testEditorFocusChangesNothingOnTheOtherTabs() {
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: true), .none)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: false), .none)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .margins, timelineEditorHasFocus: true), .libraryExit)
    }

    /// #4453: following scrolls the Now header, which holds the Library arrow, out of sight; the toolbar shows it then.
    func testNowShowsTheLibraryArrowInTheToolbarOnlyWhileItsHeaderIsOutOfView() {
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: false, nowHeaderIsVisible: true), .none)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: false, nowHeaderIsVisible: false), .libraryExit)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: false), .none, "the default is today's")
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .timeline, timelineEditorHasFocus: false, nowHeaderIsVisible: false), .libraryExit)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .timeline, timelineEditorHasFocus: true, nowHeaderIsVisible: false), .returnToNow)
    }

    /// #4739: the bar's leading item exists, with the same kind, whether or not the Now header is on screen. Only its
    /// visibility may follow the header; anything else makes the bar's size depend on scroll state.
    func testToolbarItemDoesNotDependOnHeaderVisibility() {
        for pane in [PlaybackLeadingControl.Pane.now, .timeline, .margins] {
            for editorFocus in [false, true] {
                let shown = PlaybackLeadingControl.slot(pane: pane, timelineEditorHasFocus: editorFocus, nowHeaderIsVisible: true)
                let hidden = PlaybackLeadingControl.slot(pane: pane, timelineEditorHasFocus: editorFocus, nowHeaderIsVisible: false)
                let label = "pane \(pane), editor focus \(editorFocus)"
                XCTAssertEqual(shown.kind, hidden.kind, "same kind either way: \(label)")
            }
        }
    }

    func testOnNowTheArrowIsDrawnOnlyWhileTheHeaderIsOutOfView() {
        XCTAssertEqual(PlaybackLeadingControl.slot(pane: .now, timelineEditorHasFocus: false, nowHeaderIsVisible: true).isShown, false)
        XCTAssertEqual(PlaybackLeadingControl.slot(pane: .now, timelineEditorHasFocus: false, nowHeaderIsVisible: false).isShown, true)
        XCTAssertEqual(PlaybackLeadingControl.slot(pane: .timeline, timelineEditorHasFocus: true, nowHeaderIsVisible: true).kind, .returnToNow)
        XCTAssertEqual(PlaybackLeadingControl.slot(pane: .margins, timelineEditorHasFocus: false, nowHeaderIsVisible: true).isShown, true)
    }

    /// #4739: at the largest text size in dark mode the app hung on first launch. Showing the toolbar arrow laid the bar
    /// out again and moved a header that sat at the edge back into view, which took the arrow away, which moved the
    /// header out again, on every pass. Here the header shows 0.5% of itself without the arrow and 30% with it.
    func testABarLayoutThatMovesTheHeaderCannotFlipTheArrowBackAndForth() {
        var header = NowHeaderVisibility()
        var flips = 0
        var shown = PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: false, nowHeaderIsVisible: header.isVisible)
        for _ in 0..<50 {
            header.seen(fraction: shown == .libraryExit ? 0.3 : 0.005)
            let next = PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: false, nowHeaderIsVisible: header.isVisible)
            if next != shown { flips += 1 }
            shown = next
        }
        XCTAssertEqual(flips, 1, "the arrow must settle after one change, not flip on every layout pass")
        XCTAssertEqual(shown, .libraryExit)
    }

    func testTheHeaderIsGoneOnlyWhenAlmostNoneOfItShowsAndBackOnlyWhenAlmostAllOfItDoes() {
        // (share on screen, starting visible, expected after)
        let rows: [(Double, Bool, Bool)] = [
            (1.0, true, true), (0.5, true, true), (0.01, true, true), (0.009, true, false), (0.0, true, false),
            (0.0, false, false), (0.009, false, false), (0.01, false, false), (0.3, false, false), (0.89, false, false),
            (0.9, false, true), (1.0, false, true),
        ]
        for (fraction, start, expected) in rows {
            var header = NowHeaderVisibility(isVisible: start)
            header.seen(fraction: fraction)
            XCTAssertEqual(header.isVisible, expected, "\(fraction) of the header, starting \(start ? "visible" : "gone")")
        }
    }

    func testEachThresholdMovesTheStateOnlyOneWay() {
        var header = NowHeaderVisibility()
        header.reachedBackThreshold(false)
        XCTAssertTrue(header.isVisible, "less than the back threshold never hides a visible header")
        header.reachedGoneThreshold(false)
        XCTAssertFalse(header.isVisible)
        header.reachedGoneThreshold(true)
        XCTAssertFalse(header.isVisible, "a sliver back in view does not bring the arrow back to the header")
        header.reachedBackThreshold(true)
        XCTAssertTrue(header.isVisible)
        XCTAssertTrue(NowHeaderVisibility().isVisible, "a new screen starts with its header in view, as before")
    }
}
