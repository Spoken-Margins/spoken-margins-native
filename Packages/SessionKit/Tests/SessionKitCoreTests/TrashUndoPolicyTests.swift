import XCTest
@testable import SessionKit

/// #1926: the Undo banner's 5 second timer gave a VoiceOver or Switch Control listener no time to reach Undo.
final class TrashUndoPolicyTests: XCTestCase {
    func testTheBannerKeepsItsTimerWhenNoAssistiveTechnologyIsRunning() {
        XCTAssertFalse(TrashUndoPolicy.staysUntilDismissed(assistiveTechnologyRunning: false))
    }

    func testTheBannerStaysUntilDismissedWhenVoiceOverOrSwitchControlIsRunning() {
        XCTAssertTrue(TrashUndoPolicy.staysUntilDismissed(assistiveTechnologyRunning: true))
    }
}
