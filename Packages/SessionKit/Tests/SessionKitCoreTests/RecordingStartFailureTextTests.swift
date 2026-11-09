import XCTest
@testable import SessionKit

/// #3633: a recorder that refuses to start used to read as the generic "Something went wrong" line.
final class RecordingStartFailureTextTests: XCTestCase {
    func testARecorderThatWouldNotStartHasItsOwnSentence() {
        XCTAssertEqual(
            ListenerErrorText.message(for: SessionKitError.persistenceFailed("recording_failed")),
            "Couldn't start recording. Try again."
        )
    }

    func testOtherPersistenceCodesStillReadAsTheGenericLine() {
        for code in ["recording_permission_denied", "recording_failed_again", "spoken_note_recording_failed", ""] {
            XCTAssertEqual(ListenerErrorText.message(for: SessionKitError.persistenceFailed(code)), ListenerErrorText.fallback, code)
        }
    }
}
