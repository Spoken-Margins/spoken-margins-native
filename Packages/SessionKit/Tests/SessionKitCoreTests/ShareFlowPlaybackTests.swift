import XCTest
@testable import SessionKit

/// #5050: opening Share while something plays pauses it. Closing is checked in the app tests.
final class ShareFlowPlaybackTests: XCTestCase {
    func testOpeningShareWhileSomethingPlaysPausesIt() {
        XCTAssertEqual(ShareFlowPlayback.onOpen(isPlaying: true), .pause)
    }

    func testOpeningShareWithNothingPlayingLeavesPlaybackAlone() {
        XCTAssertEqual(ShareFlowPlayback.onOpen(isPlaying: false), .leaveAlone)
    }

}
