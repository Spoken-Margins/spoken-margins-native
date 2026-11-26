import XCTest
@testable import SessionKit

final class PlaybackLeadingControlTests: XCTestCase {
    func testTimelineLeavesTheScreenLikeMargins() {
        // #4027: Timeline showed an arrow that went back to Now, while Margins left the screen.
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .timeline, timelineEditorHasFocus: false), .libraryExit)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .margins, timelineEditorHasFocus: false), .libraryExit)
    }

    func testEveryTabLeavesExceptTheEditorCase() {
        for pane in [PlaybackLeadingControl.Pane.now, .timeline, .margins] {
            XCTAssertNotEqual(PlaybackLeadingControl.control(pane: pane, timelineEditorHasFocus: false), .returnToNow,
                              "\(pane) must not use the top-left arrow to switch tabs")
        }
    }

    func testTheTimelineEditorKeepsAWayBackToNowWhileTheTabSwitchIsHidden() {
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .timeline, timelineEditorHasFocus: true), .returnToNow)
    }

    func testEditorFocusChangesNothingOnTheOtherTabs() {
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: true), .libraryExit)
        XCTAssertEqual(PlaybackLeadingControl.control(pane: .margins, timelineEditorHasFocus: true), .libraryExit)
    }

    /// #5329: on Now the bar's corner held an invisible copy of the arrow while the title row showed the real one, and
    /// iOS 26 drew an empty glass pill around the copy. Now always gives the shown Library arrow in the corner.
    func testNowAlwaysShowsTheLibraryArrowInTheCorner() {
        for focus in [false, true] {
            XCTAssertEqual(PlaybackLeadingControl.control(pane: .now, timelineEditorHasFocus: focus), .libraryExit)
        }
    }

    /// #5311: the J14 scripts tap the arrow by this identifier; there is one arrow, so nothing can shadow it.
    func testTheLibraryArrowKeepsTheIdentifierTheScriptsTap() {
        XCTAssertEqual(PlaybackLeadingControl.libraryExitIdentifier, "playback.exit.button")
    }
}
