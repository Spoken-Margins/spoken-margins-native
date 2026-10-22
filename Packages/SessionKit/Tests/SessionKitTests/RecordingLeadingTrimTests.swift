#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit
@testable import SessionKitAudio
import XCTest

/// #1594: on the built-in speaker the ready cue bleeds into the recording, so saving drops the start of the file.
final class RecordingLeadingTrimTests: XCTestCase {
    private let rate = 44_100.0

    func testTheStartIsGoneAndTheSpeechAfterItIsKept() throws {
        // A cue-like tone, a pause, then "speech" (a different, quieter tone) for a second.
        let url = try writeRecording(segments: [(880, 0.5, 0.3), (0, 0, 0.5), (220, 0.2, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertGreaterThan(try peak(url, fromMs: 0, forMs: 200), 0.4, "the fixture starts with the loud cue")

        let outcome = RecordingLeadingTrim.trim(url: url, leadingMs: 400)

        guard case .trimmed(let removedMs) = outcome else { return XCTFail("expected a trim, got \(outcome)") }
        XCTAssertEqual(Double(removedMs), 400, accuracy: 60)
        XCTAssertEqual(Double(try durationMs(url)), 1_800 - 400, accuracy: 100)
        XCTAssertLessThan(try peak(url, fromMs: 0, forMs: 100), 0.05, "no cue left at the start: the pause comes first now")
        XCTAssertGreaterThan(try peak(url, fromMs: 700, forMs: 300), 0.12, "the speech is intact")
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(try leftoverTemporaries(beside: url), [], "no half-written copy is left beside the recording")
    }

    func testARecordingThatIsLittleMoreThanTheCueIsLeftWhole() throws {
        let url = try writeRecording(segments: [(880, 0.5, 0.3), (0, 0, 0.2)])
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)

        let outcome = RecordingLeadingTrim.trim(url: url, leadingMs: 340)

        XCTAssertEqual(outcome, .skipped("shorter_than_cue"))
        XCTAssertEqual(try Data(contentsOf: url), original, "nothing is cut from a Margin that would be left empty")
    }

    func testAnUnreadableFileIsLeftExactlyAsItWas() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let damaged = Data(repeating: 0x5A, count: 4_096)
        try damaged.write(to: url)

        XCTAssertEqual(RecordingLeadingTrim.trim(url: url, leadingMs: 340), .skipped("unreadable"))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testNothingToTrimChangesNothing() throws {
        let url = try writeRecording(segments: [(220, 0.2, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)

        XCTAssertEqual(RecordingLeadingTrim.trim(url: url, leadingMs: 0), .skipped("nothing_to_trim"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTheTrimmedFileStillPassesTheSaveIntegrityCheck() throws {
        // The clock says 5.0 s were recorded; the cue took 0.34 s of them, so the file must hold about 4.66 s.
        let url = try writeRecording(segments: [(880, 0.5, 0.3), (220, 0.2, 4.7)])
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .trimmed(let removedMs) = RecordingLeadingTrim.trim(url: url, leadingMs: 340) else { return XCTFail("expected a trim") }
        let integrity = RecordingFileFinalizer.finish(url: url, reportedMs: 5_000 - removedMs, stop: {})

        XCTAssertFalse(integrity.needsWarning)
        XCTAssertEqual(Double(try XCTUnwrap(integrity.fileMs)), 4_660, accuracy: 100)
    }

    // MARK: Fixtures

    /// AAC mono audio from (frequency Hz, amplitude, seconds) segments; frequency 0 is silence.
    private func writeRecording(segments: [(Double, Double, Double)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        for (frequency, amplitude, seconds) in segments {
            let frames = AVAudioFrameCount(seconds * rate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<Int(frames) {
                samples[i] = frequency == 0 ? 0 : Float(sin(Double(i) * 2 * .pi * frequency / rate) * amplitude)
            }
            try file?.write(from: buffer)
        }
        file = nil // the closing index of an AAC file is written when the writer goes
        return url
    }

    private func durationMs(_ url: URL) throws -> Int {
        guard case .milliseconds(let ms) = RecordedFileDuration.measure(url) else { throw CocoaError(.fileReadCorruptFile) }
        return ms
    }

    /// The loudest sample in a window of the decoded file.
    private func peak(_ url: URL, fromMs: Int, forMs: Int) throws -> Float {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = AVAudioFramePosition(Double(fromMs) / 1_000 * file.processingFormat.sampleRate)
        let frames = AVAudioFrameCount(Double(forMs) / 1_000 * file.processingFormat.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer, frameCount: frames)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
    }

    private func leftoverTemporaries(beside url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".readycue-") }
    }
}
#endif
