import XCTest
import SessionKit

/// The two clock rules of the Margin voice pollers (#993). Values sit clearly inside or outside the tolerance:
/// `2.0 - 0.05` is not exactly `1.95` in binary, so an exact-boundary row would test the float, not the rule.
final class MarginVoiceClockReadingTests: XCTestCase {
    func testAVoiceHasSoundedOnlyOnceTheClockIsPositiveAndFinite() {
        for current in [Double.nan, .infinity, -.infinity, -1, -0.0, 0] {
            XCTAssertFalse(MarginVoiceClockReading(duration: 2, current: current).hasSounded, "current \(current)")
        }
        for current in [0.0001, 0.5, 2, 3] {
            XCTAssertTrue(MarginVoiceClockReading(duration: 2, current: current).hasSounded, "current \(current)")
        }
        XCTAssertTrue(MarginVoiceClockReading(duration: .nan, current: 0.5).hasSounded, "sounding does not depend on the duration")
    }

    func testAVoiceHasEndedWhenTheClockIsWithinTheToleranceOfAKnownDuration() {
        for current in [1.96, 1.99, 2, 2.5] {
            XCTAssertTrue(MarginVoiceClockReading(duration: 2, current: current).hasReachedEnd, "current \(current)")
        }
        for current in [0.0, 0.0001, 1.0, 1.9, 1.94] {
            XCTAssertFalse(MarginVoiceClockReading(duration: 2, current: current).hasReachedEnd, "current \(current)")
        }
    }

    func testAnUnknownOrEmptyDurationNeverEndsAVoice() {
        for duration in [Double.nan, .infinity, -1, 0] {
            XCTAssertFalse(MarginVoiceClockReading(duration: duration, current: 5).hasReachedEnd, "duration \(duration)")
        }
    }

    func testAnUnreadableClockNeverEndsAVoice() {
        for current in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(MarginVoiceClockReading(duration: 2, current: current).hasReachedEnd, "current \(current)")
        }
    }

    func testTheToleranceIsFiftyMilliseconds() {
        XCTAssertEqual(MarginVoiceClockReading.endTolerance, 0.05)
    }
}
