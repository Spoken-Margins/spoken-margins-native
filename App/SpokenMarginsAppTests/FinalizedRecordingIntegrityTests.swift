import AVFoundation
import Foundation
import XCTest
import SessionKit
@testable import SessionKitAudio
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class FinalizedRecordingIntegrityTests: XCTestCase {
    func testNormalSaveWarnsOnShortFileAndKeepsTheSavedMarginAndSource() throws {
        try withLibrary { model, recorder, audio, database in
            try begin(model)
            let original = try Data(contentsOf: recorder.url)
            model.finishInterjection()
            try assertSavedShortRecording(model, recorder, audio, database, original)
        }
    }

    func testCompactSaveAlsoQualifiesTheFinalizedFile() throws {
        try withLibrary { model, recorder, audio, database in
            try begin(model)
            let original = try Data(contentsOf: recorder.url)
            model.dispatchGate2CompactCommand(.finishInterjection)
            try assertSavedShortRecording(model, recorder, audio, database, original)
        }
    }

    func testUnreadableFileIsSavedAsUnverifiedWithoutStrandingCapture() throws {
        try withLibrary { model, recorder, audio, database in
            recorder.unreadable = true
            try begin(model)
            let original = try Data(contentsOf: recorder.url)
            model.finishInterjection()
            XCTAssertFalse(model.snapshot.isRecording)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(model.statusMessage, "Margin saved, but its recording could not be checked. Please play it back.")
            XCTAssertEqual(model.feedbackEvent?.kind, .warning)
            XCTAssertEqual(model.feedbackEvent?.message, model.statusMessage)
            XCTAssertNil(model.lastError)
            let session = try XCTUnwrap(model.snapshot.sessionId)
            let saved = try SQLiteSessionStore(path: database.path).loadInterjections(sessionId: session)
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.audioPath, recorder.url.path)
            XCTAssertEqual(try Data(contentsOf: recorder.url), original)
        }
    }

    /// This checks app/engine use of the injected client's current report. The production client's
    /// begin/cancel reset is inspected separately; this boundary does not pretend to test microphone lifecycle.
    func testAnotherCaptureAndCancelDoNotReuseThePreviousWarning() throws {
        try withLibrary { model, recorder, audio, _ in
            try begin(model)
            model.finishInterjection()
            XCTAssertTrue(model.engine?.finalizedRecordingIntegrity()?.needsWarning == true)
            let firstURL = recorder.url
            let original = try Data(contentsOf: firstURL)

            model.dispatchGate2CompactCommand(.beginInterjection)
            XCTAssertTrue(model.snapshot.isRecording)
            XCTAssertNil(model.engine?.finalizedRecordingIntegrity())
            model.dispatchGate2CompactCommand(.cancelInterjection)
            XCTAssertNil(model.engine?.finalizedRecordingIntegrity())
            XCTAssertFalse(model.snapshot.isRecording)
            XCTAssertEqual(try Data(contentsOf: firstURL), original)

            recorder.seconds = 5
            recorder.reportedMs = 5_000
            model.dispatchGate2CompactCommand(.beginInterjection)
            model.finishInterjection()
            XCTAssertFalse(model.snapshot.isRecording)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(model.statusMessage, "Margin saved. Transcription is continuing in the background.")
        }
    }

    private func begin(_ model: Gate1AppModel) throws {
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
    }

    private func assertSavedShortRecording(_ model: Gate1AppModel, _ recorder: FinalizedFileRecordingBoundary,
                                          _ audio: IntegrityAudioBoundary, _ database: URL, _ original: Data) throws {
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertTrue(audio.isPlaying, "A warning must not strand Save & resume")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.statusMessage, "Margin saved, but part of it may be missing.")
        XCTAssertEqual(model.feedbackEvent?.kind, .warning)
        XCTAssertEqual(model.feedbackEvent?.message, model.statusMessage)
        let session = try XCTUnwrap(model.snapshot.sessionId)
        let saved = try SQLiteSessionStore(path: database.path).loadInterjections(sessionId: session)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.audioPath, recorder.url.path)
        XCTAssertEqual(try Data(contentsOf: recorder.url), original)
        XCTAssertEqual(model.engine?.finalizedRecordingIntegrity()?.diagnosticFields["integrity"], "cut_short")
    }

    private func withLibrary(_ body: (Gate1AppModel, FinalizedFileRecordingBoundary, IntegrityAudioBoundary, URL) throws -> Void) throws {
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        SpokenMarginsTerms.recordAcceptance()
        let root = FileManager.default.temporaryDirectory.appending(path: "finalized-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "library.sqlite")
        let recorder = FinalizedFileRecordingBoundary(root: root)
        let audio = IntegrityAudioBoundary()
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: recorder,
                                  interjectionTranscriptionHandler: { _ in "Test recording" }, databaseURLOverride: database)
        model.resetAndSeed()
        defer { if model.engine?.currentSession != nil { model.endSession() } }
        try body(model, recorder, audio, database)
    }
}

/// Only microphone delivery/clock is substituted. Finalization reads an actual AAC container; the
/// real model, engine and SQLite save the result. This deliberately models the observed lying clock.
private final class FinalizedFileRecordingBoundary: RecordingClient {
    let root: URL
    private(set) var url: URL
    var seconds = 0.3
    var reportedMs = 21_704
    var unreadable = false
    private(set) var isRecording = false
    private var integrity: FinalizedRecordingIntegrity?
    init(root: URL) { self.root = root; self.url = root.appending(path: "unused.m4a") }
    func beginRecording() throws {
        integrity = nil
        url = root.appending(path: "\(UUID().uuidString).m4a")
        if unreadable {
            try Data(repeating: 0x5A, count: 4_096).write(to: url)
        } else {
            let rate = 44_100.0
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let writer = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                                                     AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.1) }
            try writer.write(from: buffer)
        }
        isRecording = true
    }
    func finishRecording(audioRef: String?) throws -> String {
        integrity = RecordingFileFinalizer.finish(url: url, reportedMs: reportedMs) { isRecording = false }
        return url.path
    }
    func cancelRecording() throws { isRecording = false; integrity = nil }
    func captureReading() -> RecordingCaptureReading? {
        RecordingCaptureReading(recorderRunning: isRecording, capturedMs: reportedMs)
    }
    func recordingInProgressRef() -> String? { isRecording ? url.path : nil }
    func finalizedRecordingIntegrity() -> FinalizedRecordingIntegrity? { integrity }
}

private final class IntegrityAudioBoundary: AudioPlaybackClient {
    private(set) var isPlaying = false
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { isPlaying = true }
    func pause() throws { isPlaying = false }
    func stop() throws { isPlaying = false }
}
