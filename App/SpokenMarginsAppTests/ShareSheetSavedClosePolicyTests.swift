import XCTest
@testable import SpokenMarginsApp

/// #1918: the share extension closed 0.35 s after "Saved" even for a VoiceOver or Switch Control listener.
final class ShareSheetSavedClosePolicyTests: XCTestCase {
    func testASightedShareClosesItself() {
        XCTAssertTrue(ShareSheetSavedClosePolicy.closesAutomatically(voiceOverRunning: false, switchControlRunning: false))
    }

    func testVoiceOverOrSwitchControlKeepsTheSheetUntilDone() {
        XCTAssertFalse(ShareSheetSavedClosePolicy.closesAutomatically(voiceOverRunning: true, switchControlRunning: false))
        XCTAssertFalse(ShareSheetSavedClosePolicy.closesAutomatically(voiceOverRunning: false, switchControlRunning: true))
        XCTAssertFalse(ShareSheetSavedClosePolicy.closesAutomatically(voiceOverRunning: true, switchControlRunning: true))
    }

    func testTheSightedDelayIsUnchanged() {
        XCTAssertEqual(ShareSheetSavedClosePolicy.closeDelay, 0.35)
    }
}
