import XCTest
@testable import SessionKit

/// #3650: on a Bluetooth headset with the microphone open, a press is the mute gesture, and iOS reports it only as
/// input mute state changes. The owner wants a double press to end the Margin and a single press never to.
final class HeadphoneMuteGestureDetectorTests: XCTestCase {
    private func detector(muted: Bool = false) -> HeadphoneMuteGestureDetector {
        HeadphoneMuteGestureDetector(initiallyMuted: muted)
    }

    private let settled = 5_000

    func testASinglePressNeverEndsAMarginHoweverLongTheRecording() {
        for recordingMs in [settled, 30_000, 3_600_000] {
            var d = detector()
            XCTAssertEqual(
                d.observe(muted: true, recordingMs: recordingMs, sinceRouteChangeMs: nil, nowMs: recordingMs),
                .firstOfPair, "a lone mute at \(recordingMs) ms"
            )
        }
    }

    func testTwoPressesInsideTheWindowEndTheMargin() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: true, recordingMs: 5_000, sinceRouteChangeMs: nil, nowMs: 100_000), .firstOfPair)
        XCTAssertEqual(d.observe(muted: false, recordingMs: 5_300, sinceRouteChangeMs: nil, nowMs: 100_300), .endMargin)
    }

    func testTwoPressesJustOutsideTheWindowAreTwoSinglePresses() {
        var d = detector()
        let window = HeadphoneMuteGestureDetector.pairWindowMs
        XCTAssertEqual(d.observe(muted: true, recordingMs: 5_000, sinceRouteChangeMs: nil, nowMs: 100_000), .firstOfPair)
        XCTAssertEqual(
            d.observe(muted: false, recordingMs: 5_000 + window + 1, sinceRouteChangeMs: nil, nowMs: 100_000 + window + 1),
            .firstOfPair, "slower than a double press: the second starts a new pair"
        )
        var edge = detector()
        _ = edge.observe(muted: true, recordingMs: 5_000, sinceRouteChangeMs: nil, nowMs: 100_000)
        XCTAssertEqual(
            edge.observe(muted: false, recordingMs: 5_000 + window, sinceRouteChangeMs: nil, nowMs: 100_000 + window),
            .endMargin
        )
    }

    func testAPressThatLeavesTheMicrophoneMutedStillCountsAsOne() {
        var d = detector(muted: true) // muted by an earlier press: the next press unmutes
        XCTAssertEqual(d.observe(muted: false, recordingMs: 8_000, sinceRouteChangeMs: nil, nowMs: 50_000), .firstOfPair)
        XCTAssertEqual(d.observe(muted: true, recordingMs: 8_400, sinceRouteChangeMs: nil, nowMs: 50_400), .endMargin)
    }

    func testARepeatedStateIsNotAPress() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: false, recordingMs: 5_000, sinceRouteChangeMs: nil, nowMs: 1_000), .ignore(.noChange))
        XCTAssertEqual(d.observe(muted: false, recordingMs: 5_100, sinceRouteChangeMs: nil, nowMs: 1_100), .ignore(.noChange))
        XCTAssertEqual(d.observe(muted: true, recordingMs: 5_200, sinceRouteChangeMs: nil, nowMs: 1_200), .firstOfPair)
        XCTAssertEqual(
            d.observe(muted: true, recordingMs: 5_300, sinceRouteChangeMs: nil, nowMs: 1_300),
            .ignore(.noChange), "the same state twice is one press, not two"
        )
    }

    func testNothingCountsInTheFirstMomentOfARecording() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: true, recordingMs: 100, sinceRouteChangeMs: nil, nowMs: 100), .ignore(.recordingJustStarted))
        XCTAssertEqual(d.observe(muted: false, recordingMs: 400, sinceRouteChangeMs: nil, nowMs: 400), .ignore(.recordingJustStarted))
        let edge = RecordingTransportGuard.startGraceMs
        var d2 = detector()
        XCTAssertEqual(d2.observe(muted: true, recordingMs: edge - 1, sinceRouteChangeMs: nil, nowMs: 1), .ignore(.recordingJustStarted))
        XCTAssertEqual(d2.observe(muted: false, recordingMs: edge, sinceRouteChangeMs: nil, nowMs: 2), .firstOfPair)
    }

    func testAPhantomPairInTheStartWindowDoesNotEndTheMarginOrCarryOver() {
        var d = detector()
        _ = d.observe(muted: true, recordingMs: 200, sinceRouteChangeMs: nil, nowMs: 200)
        _ = d.observe(muted: false, recordingMs: 700, sinceRouteChangeMs: nil, nowMs: 700)
        XCTAssertEqual(
            d.observe(muted: true, recordingMs: 2_000, sinceRouteChangeMs: nil, nowMs: 2_000),
            .firstOfPair, "a phantom before the window does not count as the first press"
        )
    }

    func testNothingCountsJustAfterARouteChange() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: true, recordingMs: 9_000, sinceRouteChangeMs: 0, nowMs: 9_000), .ignore(.routeJustChanged))
        XCTAssertEqual(d.observe(muted: false, recordingMs: 9_200, sinceRouteChangeMs: 200, nowMs: 9_200), .ignore(.routeJustChanged))
        XCTAssertEqual(d.observe(muted: true, recordingMs: 20_000, sinceRouteChangeMs: RecordingTransportGuard.routeChangeGraceMs, nowMs: 20_000), .firstOfPair)
    }

    func testATriplePressEndsOnTheSecondAndTheThirdStartsNothing() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: true, recordingMs: 6_000, sinceRouteChangeMs: nil, nowMs: 6_000), .firstOfPair)
        XCTAssertEqual(d.observe(muted: false, recordingMs: 6_250, sinceRouteChangeMs: nil, nowMs: 6_250), .endMargin)
        XCTAssertEqual(
            d.observe(muted: true, recordingMs: 6_500, sinceRouteChangeMs: nil, nowMs: 6_500),
            .firstOfPair, "after the end the third press is only a first press again"
        )
    }

    func testTheWindowIsShorterThanTheSlowestDoublePressOfARelaxedListener() {
        XCTAssertLessThanOrEqual(HeadphoneMuteGestureDetector.pairWindowMs, 600)
        XCTAssertGreaterThanOrEqual(HeadphoneMuteGestureDetector.pairWindowMs, 400)
    }
}
