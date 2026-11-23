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
}
