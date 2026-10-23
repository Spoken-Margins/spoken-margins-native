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

    /// #2182: the owner's phantom `play` came 2,182 ms in, on a hands-free Bluetooth recording, after the 1.5 s window.
    func testABarePlayOnAHandsFreeInputNeverEndsTheMarginHoweverLateItComes() {
        for recordingMs in [14, 38, 2_182, 60_000, 3_600_000] {
            XCTAssertNotEqual(
                RecordingTransportGuard.verdict(command: .play, recordingMs: recordingMs, sinceRouteChangeMs: nil, onHandsFreeProfile: true),
                .endMargin,
                "play at \(recordingMs) ms"
            )
        }
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .play, recordingMs: 2_182, sinceRouteChangeMs: nil, onHandsFreeProfile: true),
            .ignore(.barePlayOnHandsFree)
        )
    }

    /// #1030: a real press still ends the Margin. Pause and the toggle on a hands-free input, and `play` on any other
    /// route (the Lock Screen button and wired headsets), keep ending it.
    func testRealPressesStillEndTheMargin() {
        for command in [CompactControlCommand.pause, .togglePlayPause, .skipForward] {
            XCTAssertEqual(
                RecordingTransportGuard.verdict(command: command, recordingMs: 2_182, sinceRouteChangeMs: nil, onHandsFreeProfile: true),
                .endMargin, "\(command)"
            )
        }
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .play, recordingMs: 2_182, sinceRouteChangeMs: nil, onHandsFreeProfile: false),
            .endMargin
        )
    }

    func testTheEarlierReasonsStillNameThemselvesForABarePlayOnAHandsFreeInput() {
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .play, recordingMs: 14, sinceRouteChangeMs: nil, onHandsFreeProfile: true),
            .ignore(.recordingJustStarted)
        )
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .play, recordingMs: 20_000, sinceRouteChangeMs: 10, onHandsFreeProfile: true),
            .ignore(.routeJustChanged)
        )
    }
}
