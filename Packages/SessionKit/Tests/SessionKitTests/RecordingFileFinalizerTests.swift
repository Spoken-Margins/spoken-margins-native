#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit
@testable import SessionKitAudio
import XCTest

final class RecordingFileFinalizerTests: XCTestCase {
    func testHealthyRecorderClockCannotCertifyAShortAACFile() throws {
        try withAudio(seconds: 0.3, extension: "m4a") { url in
            let original = try Data(contentsOf: url)
            let result = RecordingFileFinalizer.finish(url: url, reportedMs: 21_704, stop: {})
            XCTAssertEqual(Double(try XCTUnwrap(result.fileMs)), 300, accuracy: 80)
            XCTAssertEqual(result.qualifying(.save), .saveCutShort)
            XCTAssertEqual(result.diagnosticFields["integrity"], "cut_short")
            XCTAssertEqual(try Data(contentsOf: url), original, "Qualification must not alter the only original")
        }
    }

    func testCompleteAACAndSilentCAFKeepTheirSamplesWithoutAWarning() throws {
        for fileExtension in ["m4a", "caf"] {
            try withAudio(seconds: 5, extension: fileExtension, silent: fileExtension == "caf") { url in
                let original = try Data(contentsOf: url)
                let result = RecordingFileFinalizer.finish(url: url, reportedMs: 5_000, stop: {})
                XCTAssertEqual(Double(try XCTUnwrap(result.fileMs)), 5_000, accuracy: 80)
                XCTAssertFalse(result.needsWarning, "Silence is audio duration, not missing capture")
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }

    func testLegitimatelyBriefAndThresholdNeighboursAreNotMisreported() throws {
        try withAudio(seconds: 0.3, extension: "m4a") { url in
            XCTAssertFalse(RecordingFileFinalizer.finish(url: url, reportedMs: 300, stop: {}).needsWarning)
        }
        XCTAssertFalse(FinalizedRecordingIntegrity(reportedMs: 3_999, fileMs: 300).needsWarning)
        XCTAssertTrue(FinalizedRecordingIntegrity(reportedMs: 4_000, fileMs: 1_999).needsWarning)
        XCTAssertFalse(FinalizedRecordingIntegrity(reportedMs: 4_000, fileMs: 2_000).needsWarning)
    }

    func testMeasurementHappensAfterTheWriterHasClosed() throws {
        let url = temporaryURL(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        var writer: AVAudioFile? = try writeAudio(url: url, seconds: 5)
        var stopped = false
        let result = RecordingFileFinalizer.finish(url: url, reportedMs: 5_000) {
            writer = nil // AAC's closing index is written by the real AVAudioFile, not a fake measurement.
            stopped = true
        }
        XCTAssertTrue(stopped)
        XCTAssertNil(writer)
        XCTAssertEqual(Double(try XCTUnwrap(result.fileMs)), 5_000, accuracy: 80)
        XCTAssertFalse(result.needsWarning)
    }

    func testUnreadableOrMissingFinalizedFileNeverBecomesAnEmptyDiscard() throws {
        let url = temporaryURL(extension: "m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let damaged = Data(repeating: 0x5A, count: 4_096)
        try damaged.write(to: url)
        let result = RecordingFileFinalizer.finish(url: url, reportedMs: 21_000, stop: {})
        XCTAssertNil(result.fileMs)
        XCTAssertEqual(result.diagnosticFields["integrity"], "unverified")
        XCTAssertEqual(result.qualifying(.save), .saveCutShort)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        let missing = RecordingFileFinalizer.finish(url: temporaryURL(extension: "m4a"), reportedMs: 21_000, stop: {})
        XCTAssertEqual(missing.qualifying(.save), .saveCutShort)
    }

    func testCompleteFileCannotEraseAnInterruptionWarning() throws {
        try withAudio(seconds: 5, extension: "caf") { url in
            let result = RecordingFileFinalizer.finish(url: url, reportedMs: 5_000, stop: {})
            XCTAssertFalse(result.needsWarning)
            XCTAssertEqual(result.qualifying(.saveCutShort), .saveCutShort)
        }
    }

    func testLevelingPreservesTheShortOriginalsDecodedFrames() throws {
        try withAudio(seconds: 0.3, extension: "m4a") { url in
            let original = try Data(contentsOf: url)
            let copy = temporaryURL(extension: "caf")
            defer { try? FileManager.default.removeItem(at: copy) }
            try MarginLoudnessLeveler.renderLeveledCopy(of: url, to: copy)
            let source = try AVAudioFile(forReading: url)
            let leveled = try AVAudioFile(forReading: copy)
            XCTAssertEqual(source.length, leveled.length, "AAC priming is not lost user audio")
            XCTAssertEqual(source.processingFormat.sampleRate, leveled.processingFormat.sampleRate)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(RecordingFileFinalizer.finish(url: url, reportedMs: 21_704, stop: {}).needsWarning,
                          "The original was already short, before leveling")
        }
    }

    private func withAudio(seconds: Double, extension fileExtension: String, silent: Bool = false,
                           body: (URL) throws -> Void) throws {
        let url = temporaryURL(extension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try writeAudio(url: url, seconds: seconds, silent: silent)
        try body(url)
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    /// Returns the real writer so the read-after-close test controls its finalization.
    private func writeAudio(url: URL, seconds: Double, silent: Bool = false) throws -> AVAudioFile {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let settings = url.pathExtension == "m4a"
            ? [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: rate, AVNumberOfChannelsKey: 1] as [String: Any]
            : format.settings
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = silent ? 0 : Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.1) }
        try writer.write(from: buffer)
        return writer
    }
}
#endif
