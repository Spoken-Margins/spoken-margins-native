import XCTest
@testable import SessionKit

/// The skip distances for podcasts and other timed media (#974). The saved values and the unit string are
/// what the Settings pickers write and the engine reads, so a change here would orphan a listener's choice.
final class MediaSkipRuleTests: XCTestCase {
    func testTheListenerChoosesFromTenToSixtySecondsAndFifteenIsTheDefault() {
        XCTAssertEqual(MediaSkipRule.supportedSeconds, [10, 15, 30, 45, 60])
        XCTAssertEqual(MediaSkipRule.defaultSeconds, 15)
    }

    func testValuesOutsideTheListFallBackToFifteen() {
        for seconds in MediaSkipRule.supportedSeconds {
            XCTAssertEqual(MediaSkipRule.validated(seconds), seconds)
        }
        // 0 is what UserDefaults returns when nothing was stored.
        for seconds in [0, -15, 1, 9, 11, 14, 16, 20, 29, 31, 44, 46, 59, 61, 90, 300, Int.max, Int.min] {
            XCTAssertEqual(MediaSkipRule.validated(seconds), 15, "\(seconds)")
        }
    }

    func testTheEngineUnitIsTimeSecondsAndNeverCarriesAnUnsupportedValue() {
        XCTAssertEqual(MediaSkipRule.unit(seconds: 10), "time_10s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: 15), "time_15s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: 30), "time_30s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: 45), "time_45s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: 60), "time_60s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: 0), "time_15s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: 61), "time_15s")
        XCTAssertEqual(MediaSkipRule.unit(seconds: -30), "time_15s")
    }
}
