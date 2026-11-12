import Foundation
import SessionKitTestInputs
import XCTest
@testable import SessionKit

/// #3937: five phone-found bugs turned on the order and delay of the events a route really sends while a Margin records
/// (#1506, #1668, #1708, #2182, #3633). These replay recorded traces (`Contracts/fixtures/capture-traces/`) into the real
/// `MarginCaptureSupervisor` and `RecordingTransportGuard` on the trace's own clock.
final class CaptureTraceReplayTests: XCTestCase {
    private func replay(_ name: String) throws -> CaptureTraceReplay.Result {
        let data = try TestInputs.data(.contracts, "fixtures/capture-traces/\(name).json")
        return try CaptureTraceReplay.replay(try CaptureTrace.decode(data))
    }

    private func reasons(_ result: CaptureTraceReplay.Result) -> [String] {
        result.ignored.map { "\($0.atMs):\($0.reason.rawValue)" }
    }

    // MARK: - #2182: the phantom play at 2,182 ms

    func testThePhantomPlayAtTwoSecondsOnAHandsFreeInputDoesNotEndTheMargin() throws {
        let result = try replay("bluetooth-phantom-play-2182")
        XCTAssertEqual(reasons(result), ["14:recording_just_started", "38:recording_just_started", "2182:bare_play_on_hands_free"])
        XCTAssertEqual(result.endedAtMs, 9_500, "only the listener's pause ends it")
    }

    func testTheSameCommandsOnAWiredHeadsetEndTheMarginAtTheFirstPlay() throws {
        let result = try replay("wired-headset-play-2182-control")
        XCTAssertEqual(result.endedAtMs, 2_182, "a Lock Screen or wired play is the listener's (#1030)")
        XCTAssertEqual(result.ignored.count, 0)
    }

    // MARK: - #1708: the profile switch

    func testTheProfileSwitchPlaysAtFiftyAndFourHundredFortyMillisecondsAreIgnored() throws {
        let result = try replay("bluetooth-profile-switch-1708")
        XCTAssertEqual(Array(reasons(result).prefix(2)), ["50:recording_just_started", "440:recording_just_started"])
    }

    func testACommandJustAfterARouteChangeIsIgnoredAndTheRealClickLaterEndsIt() throws {
        let result = try replay("bluetooth-profile-switch-1708")
        XCTAssertEqual(reasons(result).last, "6400:route_just_changed")
        XCTAssertEqual(result.endedAtMs, 13_200)
    }

    // MARK: - #1506 and #937: how long the microphone takes to open

    func testAMicrophoneThatOpensIn1500msIsSlowNotFailed() throws {
        let result = try replay("bluetooth-slow-microphone-1506")
        XCTAssertEqual(result.healthChanges, [.starting, .capturing])
        XCTAssertEqual(result.restarts, 0, "1.5 s is inside the 2 s the start may take")
    }

    func testARecorderThatNeverGetsAudioIsRestartedOnceAfterTheGrace() throws {
        let result = try replay("bluetooth-microphone-never-opens-937")
        XCTAssertEqual(result.healthChanges.first, .starting)
        XCTAssertEqual(result.restarts, 1)
        XCTAssertEqual(result.steps.first { $0.outcome == .restarted }?.atMs, 2_100,
                       "the first reading past the 2 s grace")
        XCTAssertEqual(result.healthChanges.last, .capturing, "the restarted recorder's audio is accepted")
    }

    // MARK: - The format: each case is one way a trace can be wrong

    /// The error a trace is refused with, or nil if it replays (kept out of an assertion: see TestInputs.swift).
    private func refusal(_ trace: CaptureTrace) -> CaptureTraceReplay.TraceError? {
        do { _ = try CaptureTraceReplay.replay(trace); return nil } catch {
            guard let known = error as? CaptureTraceReplay.TraceError else { XCTFail("\(error)"); return nil }
            return known
        }
    }

    func testATraceThatIsNotInOrderIsRefusedNotReplayed() {
        let trace = CaptureTrace(name: "x", source: "test", events: [
            .init(atMs: 0, kind: .recordingStarted, inputs: ["BluetoothHFP"]),
            .init(atMs: 500, kind: .command, command: .play, origin: "now_playing"),
            .init(atMs: 400, kind: .command, command: .play, origin: "now_playing"),
        ])
        XCTAssertEqual(refusal(trace), .outOfOrder(atMs: 400, after: 500))
    }

    func testAnEventMissingItsFieldsAndAWrongFormatAreRefused() {
        var trace = CaptureTrace(name: "x", source: "test", events: [.init(atMs: 0, kind: .recordingStarted)])
        XCTAssertEqual(refusal(trace), .missing("inputs", atMs: 0))
        trace.events = [.init(atMs: 0, kind: .recordingStarted, inputs: []), .init(atMs: 1, kind: .recordingStarted, inputs: [])]
        XCTAssertEqual(refusal(trace), .startedTwice(atMs: 1))
        trace.format = "capture-trace/2"
        XCTAssertEqual(refusal(trace), .wrongFormat("capture-trace/2"))
    }

    func testCommandsThatCannotEndAMarginArePassedOnNotJudged() throws {
        let trace = CaptureTrace(name: "x", source: "test", events: [
            .init(atMs: 0, kind: .recordingStarted, inputs: ["BluetoothHFP"]),
            .init(atMs: 3_000, kind: .command, command: .skipBack, origin: "now_playing"),
            .init(atMs: 3_100, kind: .command, command: .play, origin: "widget"),
            .init(atMs: 3_200, kind: .nowPlayingInfo),
        ])
        let result = try CaptureTraceReplay.replay(trace)
        XCTAssertEqual(result.steps.suffix(2).map(\.outcome), [.commandPassedOn(.skipBack), .commandPassedOn(.play)])
        XCTAssertNil(result.endedAtMs, "a stale widget command must not save a Margin (#1030)")
    }

    func testAnyTraceFixtureInTheFolderDecodesAndReplays() throws {
        let folder = try TestInputs.url(.contracts, "fixtures/capture-traces")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 5)
        for file in files {
            let bytes = try Data(contentsOf: file)
            let trace = try CaptureTrace.decode(bytes)
            XCTAssertFalse(trace.source.isEmpty, "\(file.lastPathComponent) says where it came from")
            XCTAssertNil(refusal(trace), file.lastPathComponent)
        }
    }
}
