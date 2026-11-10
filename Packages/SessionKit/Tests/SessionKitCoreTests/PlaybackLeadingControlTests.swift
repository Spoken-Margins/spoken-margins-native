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
}
