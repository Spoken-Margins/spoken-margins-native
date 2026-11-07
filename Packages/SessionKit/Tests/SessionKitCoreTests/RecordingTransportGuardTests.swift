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

    /// #1030: skip forward on a hands-free input, and every command on any other route (the Lock Screen button, wired
    /// headsets, a car), keep ending the Margin.
    func testNonHeadphonePressesStillEndTheMargin() {
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .skipForward, recordingMs: 2_182, sinceRouteChangeMs: nil, onHandsFreeProfile: true),
            .endMargin
        )
        for command in [CompactControlCommand.play, .pause, .togglePlayPause, .skipForward] {
            XCTAssertEqual(
                RecordingTransportGuard.verdict(command: command, recordingMs: 2_182, sinceRouteChangeMs: nil, onHandsFreeProfile: false),
                .endMargin, "\(command)"
            )
        }
    }

    /// Owner, 2026-11-07 (#3650): a single press never ends a Margin on a hands-free input. A lone pause or toggle
    /// there is a press or the profile's noise, and the two cannot be told apart.
    func testALonePauseOrToggleOnAHandsFreeInputNeverEndsTheMargin() {
        for command in [CompactControlCommand.pause, .togglePlayPause] {
            for recordingMs in [2_182, 60_000] {
                XCTAssertEqual(
                    RecordingTransportGuard.verdict(command: command, recordingMs: recordingMs, sinceRouteChangeMs: nil, onHandsFreeProfile: true),
                    .ignore(.lonePressOnHandsFree), "\(command) at \(recordingMs) ms"
                )
            }
        }
    }

    /// The double press is the next-track command, which reaches the guard as skip forward. It ends the Margin on a
    /// hands-free input, still not in the first moment or just after a route change.
    func testADoublePressEndsTheMarginOnAHandsFreeInputOutsideTheNoisyWindows() {
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .skipForward, recordingMs: 5_000, sinceRouteChangeMs: nil, onHandsFreeProfile: true, isDoublePress: true),
            .endMargin
        )
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .skipForward, recordingMs: 200, sinceRouteChangeMs: nil, onHandsFreeProfile: true, isDoublePress: true),
            .ignore(.recordingJustStarted)
        )
        XCTAssertEqual(
            RecordingTransportGuard.verdict(command: .skipForward, recordingMs: 5_000, sinceRouteChangeMs: 300, onHandsFreeProfile: true, isDoublePress: true),
            .ignore(.routeJustChanged)
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
