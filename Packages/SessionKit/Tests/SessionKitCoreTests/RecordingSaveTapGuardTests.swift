import Foundation
import XCTest
@testable import SessionKit

/// #148: a quick double tap on Add a Margin can land its second tap on Save & resume as the recording screen
/// appears, saving an empty Margin. Save ignores taps for a short window after the screen appears.
final class RecordingSaveTapGuardTests: XCTestCase {
    private let appeared = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testASecondTapOfADoubleTapIsIgnored() {
        let guardWindow = RecordingSaveTapGuard(appearedAt: appeared)
        XCTAssertFalse(guardWindow.accepts(tapAt: appeared))
        XCTAssertFalse(guardWindow.accepts(tapAt: appeared.addingTimeInterval(0.2)), "a double tap's second tap lands about 0.2 s later")
    }

    func testATapAfterTheWindowSaves() {
        let guardWindow = RecordingSaveTapGuard(appearedAt: appeared)
        XCTAssertTrue(guardWindow.accepts(tapAt: appeared.addingTimeInterval(RecordingSaveTapGuard.window)))
        XCTAssertTrue(guardWindow.accepts(tapAt: appeared.addingTimeInterval(4)))
    }

    func testTheWindowStartsAtHalfASecond() {
        XCTAssertEqual(RecordingSaveTapGuard.window, 0.5)
    }
}
