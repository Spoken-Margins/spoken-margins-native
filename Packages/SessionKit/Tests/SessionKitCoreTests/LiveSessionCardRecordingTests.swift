import XCTest
@testable import SessionKit

/// #3499: the live session card must say a spoken Margin is recording only while one is, and never after End.
final class LiveSessionCardRecordingTests: XCTestCase {
    func testTheCardSaysRecordingOnlyWhileARunningSessionRecords() {
        XCTAssertEqual(LiveSessionCardRecording.flag(isRunning: true, isRecordingSpoken: true), true)
    }

    func testAnIdleRunningSessionLeavesTheFlagUnset() {
        XCTAssertNil(LiveSessionCardRecording.flag(isRunning: true, isRecordingSpoken: false))
    }

    func testAnEndedSessionNeverReadsAsRecording() {
        XCTAssertNil(LiveSessionCardRecording.flag(isRunning: false, isRecordingSpoken: true))
        XCTAssertNil(LiveSessionCardRecording.flag(isRunning: false, isRecordingSpoken: false))
    }
}
