import XCTest
@testable import SessionKit

/// #5050: opening Share while something plays pauses it, and closing the flow doesn't resume it.
final class ShareFlowPlaybackTests: XCTestCase {
    func testOpeningShareWhileSomethingPlaysPausesIt() {
        XCTAssertEqual(ShareFlowPlayback.onOpen(isPlaying: true), .pause)
    }

    func testOpeningShareWithNothingPlayingLeavesPlaybackAlone() {
        XCTAssertEqual(ShareFlowPlayback.onOpen(isPlaying: false), .leaveAlone)
    }

    func testClosingTheShareFlowNeverResumesAPausedSource() {
        XCTAssertEqual(ShareFlowPlayback.onClose(isPlaying: false), .leaveAlone)
    }

    func testClosingTheShareFlowLeavesASourceTheListenerRestartedPlaying() {
        XCTAssertEqual(ShareFlowPlayback.onClose(isPlaying: true), .leaveAlone)
    }
}
