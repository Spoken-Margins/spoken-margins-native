#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit
import XCTest
@testable import SessionKitAudio

/// #3940, PR 2: the real cut, against a real generated tone file and real AVFoundation (no fake at the boundary
/// that matters). The transcripts are fixtures: what the recogniser said is not the thing under test.
final class MarginEndPhraseTrimTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "margin-trim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func tone(seconds: Double) throws -> URL {
        let url = directory.appending(path: "margin.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { samples[frame] = Float(0.3 * sin(2 * .pi * 440 * Double(frame) / 44_100)) }
        try file.write(from: buffer)
        return url
    }

    private func transcript(_ pieces: [String], text: String, from start: Int = 200) -> AlignedInterjectionTranscript {
        AlignedInterjectionTranscript(
            text: text,
            localeIdentifier: "en_US",
            segments: pieces.enumerated().map {
                let begin = start + $0.offset * 400
                return AlignedTranscriptSegment(id: "seg-\($0.offset + 1)", text: $0.element, startMs: begin, endMs: begin + 300)
            }
        )
    }

    func testThePhraseIsCutFromTheFileAndTheWords() async throws {
        let url = try tone(seconds: 4)
        // "point" ends at 1,700 ms and "stop" starts at 1,800: the cut is at 1,700, the end of the last word kept.
        let said = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        let before = try Data(contentsOf: url)
        let result = await MarginEndPhraseTrim.prepare(fileURL: url, transcript: said)
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(try Data(contentsOf: url), before, "prepare changes nothing")
        XCTAssertEqual(prepared.transcript.text, "That is my point.")
        XCTAssertEqual(prepared.transcript.segments.map(\.text), ["that", "is", "my", "point"])
        XCTAssertEqual(Double(prepared.durationMs), 1_700, accuracy: 120)
        XCTAssertTrue(prepared.swapIn())
        XCTAssertEqual(RecordedFileDuration.measure(url), .milliseconds(prepared.durationMs), "the file at the same path is the short one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["margin.m4a"], "no temporary file is left beside it")
        XCTAssertFalse(prepared.swapIn(), "a second swap does nothing")
    }

    func testDiscardingLeavesTheOriginalAndNoTemporaryFile() async throws {
        let url = try tone(seconds: 4)
        let before = try Data(contentsOf: url)
        let said = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        let result = await MarginEndPhraseTrim.prepare(fileURL: url, transcript: said)
        let prepared = try XCTUnwrap(result)
        prepared.throwAway()
        XCTAssertFalse(prepared.swapIn(), "a discarded copy can't be swapped in")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["margin.m4a"])
    }

    func testAMismatchKeepsTheOriginalFileAndWords() async throws {
        let url = try tone(seconds: 4)
        let before = try Data(contentsOf: url)
        let said = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point stop marching.")
        let prepared = await MarginEndPhraseTrim.prepare(fileURL: url, transcript: said)
        XCTAssertNil(prepared)
        XCTAssertEqual(try Data(contentsOf: url), before, "the original is untouched")
    }

    func testNoPhraseKeepsEverything() async throws {
        let url = try tone(seconds: 2)
        let before = try Data(contentsOf: url)
        let prepared = await MarginEndPhraseTrim.prepare(fileURL: url, transcript: transcript(["that", "is", "it"], text: "That is it."))
        XCTAssertNil(prepared)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAFileThatWillNotOpenKeepsEverythingAndLeavesNoTemporaryFile() async throws {
        let url = directory.appending(path: "margin.m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        let prepared = await MarginEndPhraseTrim.prepare(
            fileURL: url,
            transcript: transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        )
        XCTAssertNil(prepared)
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 1, 2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["margin.m4a"])
    }

    func testTheCutIsPlannedWithoutTouchingAudioWhenTheWordsAreAllThePhrase() {
        XCTAssertNil(MarginEndPhraseTrim.plan(for: transcript(["stop", "margin"], text: "Stop margin.")))
    }
}
#endif
