import Foundation
import XCTest
@testable import SessionKit

/// #4414: a Margin started from the Lock Screen sometimes fails. The export has to say what came just before each
/// start, and what the recorder saw at the refusal, so the failures can be compared.
final class CompactBeginContextTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
        "sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"],
        "timeline": ["media_time"],
        "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"]
    ])
    private let t0 = Date(timeIntervalSince1970: 50_000)

    private func snapshot(_ status: PlaybackStatus, recording: Bool = false) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.status = status
        snapshot.isRecording = recording
        return snapshot
    }

    func testNothingSeenSaysSoForEveryField() {
        XCTAssertEqual(CompactBeginContext().fields(now: t0), [
            "sinceBackgroundS": "not_seen", "sincePlaybackStartS": "not_seen",
            "sinceRecordingEndS": "not_seen", "lastTransportOrigin": "not_seen"
        ])
    }

    func testFieldsAreWholeSecondsRoundedDownSinceEachMoment() {
        var context = CompactBeginContext()
        context.appEnteredBackground(at: t0)
        context.snapshotChanged(from: snapshot(.paused), to: snapshot(.playing), at: t0.addingTimeInterval(10))
        context.snapshotChanged(from: snapshot(.recording, recording: true), to: snapshot(.paused), at: t0.addingTimeInterval(20))
        context.noteCommand(.play, origin: "now_playing_play")

        let fields = context.fields(now: t0.addingTimeInterval(32.9))
        XCTAssertEqual(fields["sinceBackgroundS"], "32", "rounded down, never up")
        XCTAssertEqual(fields["sincePlaybackStartS"], "22")
        XCTAssertEqual(fields["sinceRecordingEndS"], "12")
        XCTAssertEqual(fields["lastTransportOrigin"], "now_playing_play")
        XCTAssertEqual(Set(fields.keys), ["sinceBackgroundS", "sincePlaybackStartS", "sinceRecordingEndS", "lastTransportOrigin"],
                       "the four names the issue asks for, nothing else")
    }

    func testOnlyTheStartOfPlaybackAndTheEndOfARecordingMoveTheirClocks() {
        var context = CompactBeginContext()
        context.snapshotChanged(from: snapshot(.playing), to: snapshot(.playing), at: t0)
        context.snapshotChanged(from: snapshot(.playing), to: snapshot(.paused), at: t0)
        context.snapshotChanged(from: snapshot(.paused), to: snapshot(.recording, recording: true), at: t0)
        XCTAssertEqual(context.fields(now: t0)["sincePlaybackStartS"], "not_seen", "playing to playing is not a start")
        XCTAssertEqual(context.fields(now: t0)["sinceRecordingEndS"], "not_seen", "a recording that began has not ended")

        context.snapshotChanged(from: snapshot(.paused), to: snapshot(.playing), at: t0.addingTimeInterval(5))
        context.snapshotChanged(from: snapshot(.playing), to: snapshot(.playing), at: t0.addingTimeInterval(9))
        XCTAssertEqual(context.fields(now: t0.addingTimeInterval(12))["sincePlaybackStartS"], "7",
                       "a later snapshot that is still playing doesn't restart the clock")
    }

    func testMarginCommandsDoNotReplaceTheLastTransportOrigin() {
        var context = CompactBeginContext()
        context.noteCommand(.togglePlayPause, origin: "now_playing_toggle")
        for command in [CompactControlCommand.beginInterjection, .finishInterjection, .cancelInterjection] {
            context.noteCommand(command, origin: "locked_margin_intent")
        }
        XCTAssertEqual(context.fields(now: t0)["lastTransportOrigin"], "now_playing_toggle")
    }

    func testAnOriginStaysOneBoundedLineAndAClockThatMovedBackReadsZero() {
        var context = CompactBeginContext()
        context.noteCommand(.skipBack, origin: "a;b=c\n" + String(repeating: "x", count: 300))
        context.appEnteredBackground(at: t0.addingTimeInterval(5))
        let fields = context.fields(now: t0)
        XCTAssertLessThan(fields["lastTransportOrigin"]?.count ?? 999, 170)
        XCTAssertFalse(fields["lastTransportOrigin"]?.contains(where: { ";=\n".contains($0) }) ?? true)
        XCTAssertEqual(fields["sinceBackgroundS"], "0")
    }

    /// The failed start's event carries the recorder's route and session details, and the timing fields, and the
    /// record's own fields win a name clash.
    func testAFailedStartPutsTheRecorderDetailsAndTheTimingOnTheEvent() throws {
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "First sentence.",
                        externalReference: nil, status: "ready")
        let engine = SessionEngine(
            profile: profile,
            repository: InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:]),
            audio: RefusalPlayer(), recorder: RefusingRecorder())
        _ = try engine.startSession(itemId: item.id)
        XCTAssertThrowsError(try engine.beginInterjection(request: MarginCaptureRequest()))

        var context = CompactBeginContext()
        context.appEnteredBackground(at: t0)
        let record = CompactBeginFailureRecord(
            appState: "background", protectedDataAvailable: .yes, origin: "locked_margin_intent",
            error: "recording_failed", cue: "played",
            details: engine.recordingCaptureDiagnostics().merging(context.fields(now: t0.addingTimeInterval(4))) { _, c in c })

        let event = record.eventFields
        XCTAssertEqual(event["recordRefusedCategory"], "playAndRecord", "the recorder's refusal details reach the event")
        XCTAssertEqual(event["recordRefusedOutputs"], "AirPlay")
        XCTAssertEqual(event["sinceBackgroundS"], "4")
        XCTAssertEqual(event["origin"], "locked_margin_intent")
        XCTAssertEqual(event["appState"], "background")
        XCTAssertFalse(record.diagnosticsLine.contains("recordRefused"), "the one-line diagnostics stay short")
    }

    func testARecordsOwnFieldsWinOverADetailOfTheSameName() {
        let record = CompactBeginFailureRecord(
            appState: "background", protectedDataAvailable: .no, origin: "real", error: "e", cue: "c",
            details: ["origin": "from details", "extra": "kept"])
        XCTAssertEqual(record.eventFields["origin"], "real")
        XCTAssertEqual(record.eventFields["extra"], "kept")
    }
}

private struct RefusalError: Error {}

private final class RefusingRecorder: RecordingClient {
    func beginRecording() throws { throw RefusalError() }
    func cancelRecording() throws {}
    func finishRecording(audioRef: String?) throws -> String { "interjections/none.m4a" }
    func captureReading() -> RecordingCaptureReading? { nil }
    func captureInputRoute() -> String? { "AirPlay" }
    func captureDiagnostics() -> [String: String] {
        ["recordRefusedCategory": "playAndRecord", "recordRefusedOutputs": "AirPlay"]
    }
}

private final class RefusalPlayer: AudioPlaybackClient {
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {}
    func pause() throws {}
    func currentCharOffset() -> Int? { 0 }
    func currentPlaybackPosition() -> PlaybackPosition? { nil }
}
