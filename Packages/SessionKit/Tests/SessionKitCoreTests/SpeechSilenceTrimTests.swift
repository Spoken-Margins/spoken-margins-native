import Foundation
import XCTest
@testable import SessionKit

/// #586: Supertonic leaves about 0.6 s of silence before a chunk's speech and 0.8 s after it, so
/// every chunk seam was a stall of more than a second.
final class SpeechSilenceTrimTests: XCTestCase {
    private let rate = 44_100

    private func silence(_ seconds: Double, noise: Float = 0) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { $0 % 2 == 0 ? noise : -noise }
    }

    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { 0.3 * Float(sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
    }

    private func seconds(_ samples: Int) -> Double { Double(samples) / Double(rate) }

    func testTheModelsSilenceAroundASentenceIsTrimmedToThePads() throws {
        let samples = silence(0.61) + speech(3.0) + silence(0.83)
        let range = try XCTUnwrap(SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate))
        XCTAssertEqual(seconds(range.lowerBound), 0.61 - SpeechSilenceTrim.leadingPadSeconds, accuracy: 0.011)
        XCTAssertEqual(seconds(samples.count - range.upperBound), 0.83 - SpeechSilenceTrim.trailingPadSeconds, accuracy: 0.011)
        // The kept audio is the speech and the two pads, nothing else.
        XCTAssertEqual(
            seconds(range.count),
            3.0 + SpeechSilenceTrim.leadingPadSeconds + SpeechSilenceTrim.trailingPadSeconds,
            accuracy: 0.021
        )
    }

    func testRoomNoiseBelowTheFloorCountsAsSilence() throws {
        let samples = silence(0.5, noise: 0.004) + speech(1.0) + silence(0.5, noise: 0.004)
        let range = try XCTUnwrap(SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate))
        XCTAssertLessThan(seconds(range.count), 1.0 + SpeechSilenceTrim.leadingPadSeconds + SpeechSilenceTrim.trailingPadSeconds + 0.03)
    }

    func testAPauseInsideTheSpeechIsKept() throws {
        let samples = silence(0.6) + speech(1.0) + silence(0.4) + speech(1.0) + silence(0.8)
        let range = try XCTUnwrap(SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate))
        let kept = Array(samples[range])
        let centre = kept[Int(Double(rate) * (SpeechSilenceTrim.leadingPadSeconds + 1.0 + 0.2))]
        XCTAssertEqual(centre, 0, "the sentence pause inside a chunk is the model's own and stays")
        XCTAssertEqual(seconds(range.count), 2.4 + SpeechSilenceTrim.leadingPadSeconds + SpeechSilenceTrim.trailingPadSeconds, accuracy: 0.021)
    }

    func testSpeechRunningToTheEdgesIsNotTrimmed() throws {
        let samples = speech(2.0)
        XCTAssertEqual(SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate), 0..<samples.count)
    }

    func testSilenceShorterThanThePadsLeavesTheChunkWhole() throws {
        let samples = silence(0.02) + speech(1.0) + silence(0.03)
        XCTAssertEqual(SpeechSilenceTrim.speechRange(in: samples, sampleRate: rate), 0..<samples.count)
    }

    func testAudioWithNoSpeechHasNoRange() {
        XCTAssertNil(SpeechSilenceTrim.speechRange(in: silence(2.0), sampleRate: rate))
        XCTAssertNil(SpeechSilenceTrim.speechRange(in: silence(2.0, noise: 0.004), sampleRate: rate))
    }

    func testDegenerateInputHasNoRange() {
        XCTAssertNil(SpeechSilenceTrim.speechRange(in: [], sampleRate: rate))
        XCTAssertNil(SpeechSilenceTrim.speechRange(in: [0.5], sampleRate: rate))
        XCTAssertNil(SpeechSilenceTrim.speechRange(in: speech(1.0), sampleRate: 0))
    }

    /// The seam a listener hears is the trailing pad, the transition delay and the leading pad. It
    /// has to be no longer than the pause the model puts between two sentences inside one chunk, or
    /// a chunk seam stands out from them. `research/C2/chunk_gap.py` measured those at 0.43–0.67 s
    /// (M2, 0.88× and 1×); a seam was 1.4 s (median) before trimming.
    func testASeamIsNoLongerThanAPauseInsideAChunk() {
        let shortestPauseBetweenSentencesInsideAChunk = 0.43
        for boundary in [RenderedSpeechChunkBoundary.sentence, .comma, .whitespace, .hard] {
            let seam = SpeechSilenceTrim.trailingPadSeconds + boundary.transitionDelay + SpeechSilenceTrim.leadingPadSeconds
            XCTAssertLessThanOrEqual(seam, shortestPauseBetweenSentencesInsideAChunk, "\(boundary)")
        }
    }
}
