import XCTest
@testable import SessionKit

/// #3650: on a Bluetooth headset with the microphone open, a press is the mute gesture, and iOS reports it only as
/// input mute state changes. The owner (2026-11-07) lets a press that changes the mute state end and save the Margin.
final class HeadphoneMuteGestureDetectorTests: XCTestCase {
    private func detector(muted: Bool = false) -> HeadphoneMuteGestureDetector {
        HeadphoneMuteGestureDetector(initiallyMuted: muted)
    }

    func testAPressThatMutesEndsTheMargin() {
        for recordingMs in [5_000, 30_000, 3_600_000] {
            var d = detector()
            XCTAssertEqual(
                d.observe(muted: true, recordingMs: recordingMs, sinceRouteChangeMs: nil),
                .endMargin, "a mute at \(recordingMs) ms"
            )
        }
    }

    func testAPressThatUnmutesEndsItToo() {
        var d = detector(muted: true)
        XCTAssertEqual(d.observe(muted: false, recordingMs: 8_000, sinceRouteChangeMs: nil), .endMargin)
    }

    func testARepeatedStateIsNotAPress() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: false, recordingMs: 5_000, sinceRouteChangeMs: nil), .ignore(.noChange))
        XCTAssertEqual(d.observe(muted: false, recordingMs: 5_100, sinceRouteChangeMs: nil), .ignore(.noChange))
        var muted = detector(muted: true)
        XCTAssertEqual(muted.observe(muted: true, recordingMs: 5_000, sinceRouteChangeMs: nil), .ignore(.noChange),
                       "the stored state re-sent when the record session goes active")
    }

    func testNothingCountsInTheFirstMomentOfARecording() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: true, recordingMs: 100, sinceRouteChangeMs: nil), .ignore(.recordingJustStarted))
        let edge = RecordingTransportGuard.startGraceMs
        var d2 = detector()
        XCTAssertEqual(d2.observe(muted: true, recordingMs: edge - 1, sinceRouteChangeMs: nil), .ignore(.recordingJustStarted))
        XCTAssertEqual(d2.observe(muted: false, recordingMs: edge, sinceRouteChangeMs: nil), .endMargin)
    }

    func testAStartUpFlipIsRememberedSoItIsNotReadAsAPressLater() {
        var d = detector()
        _ = d.observe(muted: true, recordingMs: 200, sinceRouteChangeMs: nil)
        XCTAssertEqual(
            d.observe(muted: true, recordingMs: 2_000, sinceRouteChangeMs: nil),
            .ignore(.noChange), "the flip during the start window already moved the state"
        )
    }

    func testNothingCountsJustAfterARouteChange() {
        var d = detector()
        XCTAssertEqual(d.observe(muted: true, recordingMs: 9_000, sinceRouteChangeMs: 0), .ignore(.routeJustChanged))
        XCTAssertEqual(d.observe(muted: false, recordingMs: 9_200, sinceRouteChangeMs: 200), .ignore(.routeJustChanged))
        XCTAssertEqual(d.observe(muted: true, recordingMs: 20_000, sinceRouteChangeMs: RecordingTransportGuard.routeChangeGraceMs), .endMargin)
    }

    func testTheIgnoredReasonsAreNamedInDiagnostics() {
        XCTAssertEqual(HeadphoneMuteGestureDetector.Reason.recordingJustStarted.rawValue, "recording_just_started")
        XCTAssertEqual(HeadphoneMuteGestureDetector.Reason.routeJustChanged.rawValue, "route_just_changed")
        XCTAssertEqual(HeadphoneMuteGestureDetector.Reason.noChange.rawValue, "no_change")
    }
}
