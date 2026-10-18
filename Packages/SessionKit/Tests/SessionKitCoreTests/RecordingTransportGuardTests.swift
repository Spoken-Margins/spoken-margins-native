import XCTest
@testable import SessionKit

/// #1708: on Bluetooth, the headset's switch to the hands-free profile sent a `play` 50 ms and 440 ms after a
/// Margin began recording, and the #1030 rule took it for the listener's click and saved an empty Margin.
final class RecordingTransportGuardTests: XCTestCase {
    func testTheOwnersTwoPhantomPlaysAreIgnored() {
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 50, sinceRouteChangeMs: nil), .ignore(.recordingJustStarted))
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 440, sinceRouteChangeMs: nil), .ignore(.recordingJustStarted))
    }

    func testAClickAfterTheFirstMomentEndsTheMargin() {
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: RecordingTransportGuard.startGraceMs, sinceRouteChangeMs: nil), .endMargin)
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 13_200, sinceRouteChangeMs: nil), .endMargin)
    }

    func testTheEdgesOfTheStartWindow() {
        let edge = RecordingTransportGuard.startGraceMs
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 0, sinceRouteChangeMs: nil), .ignore(.recordingJustStarted))
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: edge - 1, sinceRouteChangeMs: nil), .ignore(.recordingJustStarted))
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: edge, sinceRouteChangeMs: nil), .endMargin)
    }

    func testACommandJustAfterARouteChangeIsIgnoredEvenLateInTheRecording() {
        let edge = RecordingTransportGuard.routeChangeGraceMs
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 20_000, sinceRouteChangeMs: 0), .ignore(.routeJustChanged))
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 20_000, sinceRouteChangeMs: edge - 1), .ignore(.routeJustChanged))
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 20_000, sinceRouteChangeMs: edge), .endMargin)
    }

    func testTheStartWindowWinsWhenBothApply() {
        XCTAssertEqual(RecordingTransportGuard.verdict(recordingMs: 100, sinceRouteChangeMs: 10), .ignore(.recordingJustStarted))
    }

    /// The window has to outlast the owner's evidence yet stay short enough that a real click in a hands-free
    /// flow still works: a second and a half is under the 2 s the capture check allows a Bluetooth start (#937).
    func testTheWindowsStayShortEnoughForARealClick() {
        XCTAssertGreaterThan(RecordingTransportGuard.startGraceMs, 440)
        XCTAssertLessThanOrEqual(RecordingTransportGuard.startGraceMs, MarginCaptureTimings.startGraceMs)
        XCTAssertLessThanOrEqual(RecordingTransportGuard.routeChangeGraceMs, RecordingTransportGuard.startGraceMs)
    }
}
