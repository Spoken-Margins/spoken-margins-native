import XCTest
@testable import SessionKit

/// #5050: the source kept playing under the share dialogs and sheets for about 50 seconds.
final class ShareFlowPlaybackTests: XCTestCase {
    func testOpeningShareWhilePlayingPauses() {
        XCTAssertEqual(ShareFlowPlayback.onOpen(isPlaying: true), .pause)
    }

    func testOpeningShareWhilePausedLeavesItAlone() {
        XCTAssertEqual(ShareFlowPlayback.onOpen(isPlaying: false), .leaveAlone)
    }

    func testClosingShareNeverResumes() {
        XCTAssertEqual(ShareFlowPlayback.onClose(), .leaveAlone)
    }
}
