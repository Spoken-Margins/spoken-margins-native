import Foundation
import XCTest
@testable import SessionKit

/// What one export can say about where the seconds between the tap on Add a Margin and the first captured
/// audio went (#1506).
final class MarginCaptureStartupTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
        "sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"],
        "timeline": ["media_time"],
        "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"]
    ])

    func testEngineExportsTheTapAndTheFirstNonSilentReadingOfOneCapture() throws {
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "First sentence.",
                        externalReference: nil, status: "ready")
        let recorder = StartupRecorder()
        let engine = SessionEngine(profile: profile,
                                   repository: InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:]),
                                   audio: StartupPlayer(), recorder: recorder)
        _ = try engine.startSession(itemId: item.id)
        let request = MarginCaptureRequest()
        _ = try engine.beginInterjection(request: request)
        let started = engine.recordingCaptureDiagnostics()
        XCTAssertEqual(started["captureID"], request.id.uuidString)
        XCTAssertEqual(started["tapSource"], "engine_call", "a request that only knows the engine call says so")
        XCTAssertNotEqual(started["tapToRecorderStartedMs"], "not_observed")
        XCTAssertEqual(started["tapToFirstNonSilentObservedMs"], "not_observed")
        XCTAssertEqual(started["recorderInputRoute"], "BluetoothHFP")
        recorder.reading = .init(recorderRunning: true, capturedMs: 20, peakPowerDb: -35, inputRoute: "BluetoothHFP")
        _ = engine.recordingCaptureReading()
        let first = engine.recordingCaptureDiagnostics()
        XCTAssertNotEqual(first["tapToFirstNonSilentObservedMs"], "not_observed")
        XCTAssertEqual(first["firstNonSilentInputRoute"], "BluetoothHFP")
        _ = engine.recordingCaptureReading()
        XCTAssertEqual(engine.recordingCaptureDiagnostics(), first, "later polls don't move the first milestones")
        _ = try engine.cancelInterjection()
    }

    /// The start of a Margin runs on the main thread straight after the audio session switched. It needs the input
    /// route, not the full diagnostics, which read every session property and stat the file (#2256).
    func testStartingAMarginAsksForTheInputRouteAloneNotTheFullDiagnostics() throws {
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "First sentence.",
                        externalReference: nil, status: "ready")
        let recorder = StartupRecorder()
        let engine = SessionEngine(profile: profile,
                                   repository: InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:]),
                                   audio: StartupPlayer(), recorder: recorder)
        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection(request: MarginCaptureRequest())
        XCTAssertEqual(recorder.fullDiagnosticsReads, 0)
        recorder.inputRoute = "changed after the start"
        XCTAssertEqual(engine.recordingCaptureDiagnostics()["recorderInputRoute"], "BluetoothHFP",
                       "the field still holds the route at the recorder's start")
        _ = try engine.cancelInterjection()
    }

    func testATapNotedEarlierCountsFromThatTapNotFromTheEngineCall() {
        let tap = Date(timeIntervalSince1970: 1_000)
        let request = MarginCaptureRequest.tapped(at: tap, now: tap.addingTimeInterval(0.75), uptimeNow: 500)
        XCTAssertEqual(request.tappedAt, tap)
        XCTAssertFalse(request.startsAtEngineCall)
        var labelled = MarginCaptureTiming(request: request)
        labelled.recorderStarted(at: 500, inputRoute: nil)
        XCTAssertEqual(labelled.fields["tapSource"], "app_tap")
        XCTAssertEqual(request.uptime, 499.25, accuracy: 0.0001)
        var timing = MarginCaptureTiming(request: request)
        timing.recorderStarted(at: 501, inputRoute: "BluetoothA2DPOutput")
        XCTAssertEqual(timing.fields["tapToRecorderStartedMs"], "1750")
        let future = MarginCaptureRequest.tapped(at: tap.addingTimeInterval(5), now: tap, uptimeNow: 500)
        XCTAssertEqual(future.uptime, 500, "a tap time after now (clock correction) is not before now")
    }
}

private final class StartupRecorder: RecordingClient {
    var started = false
    var reading: RecordingCaptureReading?
    func beginRecording() throws { started = true }
    func cancelRecording() throws { started = false }
    func finishRecording(audioRef: String?) throws -> String { started = false; return "interjections/test.m4a" }
    func captureReading() -> RecordingCaptureReading? { reading }
    var inputRoute = "BluetoothHFP"
    private(set) var fullDiagnosticsReads = 0
    func captureInputRoute() -> String? { inputRoute }
    func captureDiagnostics() -> [String: String] { fullDiagnosticsReads += 1; return ["inputs": inputRoute] }
}

private final class StartupPlayer: AudioPlaybackClient {
    var playing = false
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { playing = true }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { playing = true }
    func pause() throws { playing = false }
    func currentCharOffset() -> Int? { 0 }
    func currentPlaybackPosition() -> PlaybackPosition? { nil }
}
