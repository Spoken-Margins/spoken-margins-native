import Foundation
import XCTest
@testable import SessionKit
import SessionKitSupertonic
#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import SessionKitAudio
#endif

/// #240: Supertonic babbles on long chunks of numbers and symbols (every chunk of 28 s or more in
/// the owner's arXiv test PDF was unintelligible), and on dense table numbers at any length.
final class SupertonicChunkingTests: XCTestCase {
    /// A results table flattened into prose by PDF extraction, as in arXiv:2608.09666.
    static let tableSpan = """
    Table 3 reports agreement with human judges across benchmarks. Model Overall Win Tie Loss VBench 0.8889 91.1% 8.9% 0.0 \
    T2I-CompBench 0.7421 74.2% 25.8% 0.0 GenEval 0.8125 81.3% 12.5% 6.2% Qwen2.5-VL-7B 0.6923 69.2% 23.1% 7.7% \
    GPT-4o 0.8571 85.7% 14.3% 0.0 Ours 0.9286 92.9% 7.1% 0.0 Steps 7,494 tool decisions 2,548 summaries 1,203 retries \
    312 failures Latency 12.4 s 3.8 s 0.9 s 0.27 s Cost $0.021 $0.004 $0.0007 per query, n = 1,024, p < 0.001, \
    σ = 0.042, 95% CI [0.871, 0.913].
    The evaluation agent adapts its trajectory to intermediate evidence and user specified criteria, which reduces the \
    number of samples it needs while keeping its judgments close to those of human raters.
    """

    /// The real model renders every chunk the app plans for a number-heavy table span. None may
    /// come near the ~28 s babble point. Build 29's chunker gives two chunks of about 29 s here.
    func testNumberHeavyTableSpanRendersNoChunkNearTheBabbleLength() async throws {
        let assets = try SupertonicTestModel.assets()
        let output = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-chunking-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = try SupertonicNarrationRenderer(assets: assets, outputDirectory: output, governor: OnDeviceVoiceGovernor())
        let plan = RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(Self.tableSpan))
        var durations: [String] = []
        for planned in plan {
            let result = try await renderer.render(text: planned.slice.text, voice: .m2, speed: 1, synthesisSteps: 8)
            durations.append(String(format: "%.1f", result.duration))
            XCTAssertLessThan(result.duration, 20, "\"\(planned.slice.text.prefix(50))…\" renders for \(result.duration) s")
        }
        await renderer.unload()
        print("chunk durations: \(durations.joined(separator: ", "))")
    }

    /// A chunk boundary inside a number ("0." | "8571") makes both halves unreadable.
    func testChunksNeverSplitInsideANumber() {
        let plan = RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(Self.tableSpan))
        let normalized = Array(SpeechTextNormalizer.normalize(Self.tableSpan))
        for planned in plan.dropFirst() {
            let start = planned.startOffset
            guard start >= 2 else { continue }
            // "0.|8889" and "7,|494", but not a list comma such as "0.042,| 95%".
            let before = normalized[start - 2]
            XCTAssertFalse(before.isNumber && normalized[start].isNumber && [".", ",", ":"].contains(normalized[start - 1]),
                           "split inside a number at \(start): …\(String(normalized[(start - 8)..<start]))|\(String(normalized[start..<min(normalized.count, start + 8)]))…")
        }
    }

    /// Rates measured on the Mac (voice M2, speed 1): every babble chunk was 5.4–8.2 characters a
    /// second, prose 13.3–15.3. A slow chunk is flagged only when it reads like a table or is very
    /// slow (#708); real table and prose cases are in SessionKitCoreTests' SupertonicOutputCheckTests.
    func testOutputCheckFlagsBabbleAndPassesProse() {
        let prose = String(repeating: "a", count: 139)
        XCTAssertNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 9.4))
        XCTAssertNil(SupertonicOutputCheck.problem(text: String(repeating: "a", count: 45), durationSeconds: 3.3))
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: String(repeating: "a", count: 235), durationSeconds: 29.1))
        XCTAssertNotNil(SupertonicOutputCheck.problem(
            text: "0.0 GenEval 0.8125 81.3% 12.5% 6.2% Qwen2.5-VL-7B 0.6923 69.2% 23.1% 7.7% GPT-4o 0.8571 85.7%",
            durationSeconds: 11.6))
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: String(repeating: "a", count: 77), durationSeconds: 14.3))
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 2), "lost words")
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 23), "past the length ceiling")
        XCTAssertNil(SupertonicOutputCheck.problem(text: "Print 11", durationSeconds: 1.6), "too short to judge")
        XCTAssertNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 4.7, speed: 2), "speed is accounted for")
    }

    func testSpokenCostCountsDigitsAndSymbolsAsWords() {
        XCTAssertEqual("abc".reduce(0) { $0 + RenderedSpeechChunker.spokenCost(of: $1) }, 3)
        XCTAssertEqual("91.1%".reduce(0) { $0 + RenderedSpeechChunker.spokenCost(of: $1) }, 17)
        let plan = RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(Self.tableSpan))
        for planned in plan {
            let cost = planned.slice.text.reduce(0) { $0 + RenderedSpeechChunker.spokenCost(of: $1) }
            XCTAssertLessThanOrEqual(cost, RenderedSpeechChunker.spokenCostBudget)
        }
        XCTAssertEqual(plan.last.map { $0.startOffset + $0.slice.sourceLength },
                       SpeechTextNormalizer.normalize(Self.tableSpan).count, "the plan covers the whole text")
    }

    #if os(macOS) && canImport(AVFoundation)
    /// A chunk that fails the check is read by the iOS voice into a file with Supertonic's exact
    /// format, so the player and the prepared-audio assembler accept it.
    func testSystemVoiceReadsAFlaggedChunkInSupertonicsFormat() async throws {
        let assets = try SupertonicTestModel.assets()
        let output = FileManager.default.temporaryDirectory
            .appending(path: "system-voice-chunk-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = try SupertonicNarrationRenderer(assets: assets, outputDirectory: output, governor: OnDeviceVoiceGovernor())
        let text = "Latency 12.4 s 3.8 s 0.9 s 0.27 s Cost $0.021 $0.004 $0.0007 per query, n = 1,024, p < 0.001."
        let supertonic = try await renderer.render(text: text, voice: .m2, speed: 1, synthesisSteps: 8)
        await renderer.unload(removingGeneratedAudio: false)
        let replacement = output.appending(path: "system-voice.wav")
        let duration = try await SystemVoiceChunkRenderer().render(
            text: text, voiceIdentifier: nil, matching: supertonic.audioURL, to: replacement
        )
        XCTAssertGreaterThan(duration, 2, "the iOS voice read the chunk")
        XCTAssertEqual(try AVAudioFile(forReading: replacement).processingFormat,
                       try AVAudioFile(forReading: supertonic.audioURL).processingFormat)
        XCTAssertEqual(Double(try AVAudioFile(forReading: replacement).length) / 44_100, duration, accuracy: 0.05)
    }
    #endif
}
