import XCTest
@testable import SessionKit

final class MarginCapturePollCadenceTests: XCTestCase {
    func testReadsFastWhileTheStartIsNotYetConfirmed() {
        for elapsed in [0, 50, 400, 1_200, MarginCapturePollCadence.startupWindowMs - 1] {
            XCTAssertEqual(MarginCapturePollCadence.intervalMs(elapsedMs: elapsed, cueSounded: false),
                           MarginCapturePollCadence.startupMs, "at \(elapsed) ms")
        }
    }

    func testReturnsToTheSteadyRateOnceTheCueHasSounded() {
        XCTAssertEqual(MarginCapturePollCadence.intervalMs(elapsedMs: 150, cueSounded: true), MarginCapturePollCadence.steadyMs)
    }

    func testReturnsToTheSteadyRateWhenTheStartTakesLongerThanItsWindow() {
        XCTAssertEqual(MarginCapturePollCadence.intervalMs(elapsedMs: MarginCapturePollCadence.startupWindowMs, cueSounded: false),
                       MarginCapturePollCadence.steadyMs)
        XCTAssertEqual(MarginCapturePollCadence.intervalMs(elapsedMs: 60_000, cueSounded: false), MarginCapturePollCadence.steadyMs)
    }

    func testTheFastWindowOutlastsASlowBluetoothStartAndTheCueDelayDropsBelowAPoll() {
        XCTAssertGreaterThan(MarginCapturePollCadence.startupWindowMs, MarginCaptureTimings.startGraceMs)
        XCTAssertLessThan(MarginCapturePollCadence.startupMs, MarginCapturePollCadence.steadyMs)
        // Worst case from the recorder holding its first audio to the cue: one poll.
        XCTAssertLessThanOrEqual(MarginCapturePollCadence.startupMs, 50)
    }
}
