import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitSupertonic

/// Tests of the bundled fallback voice (#849) with the real model, text front end and ONNX runtime, on the Mac.
/// The model is in the repository (Git LFS), so these skip only when it hasn't been pulled.
final class KittenRendererTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let assets = KittenAssetLocation(
        rootURL: repoRoot.appending(path: "App/SpokenMarginsApp/Resources/Kitten", directoryHint: .isDirectory))

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        // A Git LFS pointer is a few hundred bytes; the real model is about 57 MB.
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.assets.modelURL.path)[.size] as? Int) ?? 0
        guard size > 1_000_000 else { throw XCTSkip("skipped: Kitten model not pulled (git lfs pull)") }
        outputDirectory = FileManager.default.temporaryDirectory.appending(path: "kitten-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let outputDirectory { try? FileManager.default.removeItem(at: outputDirectory) }
    }

    private static let prose = [
        "The committee met on Tuesday to discuss the proposal, which had been circulating among members for several weeks and had attracted a surprising amount of criticism from both sides.",
        "Most of the objections concerned cost. A smaller group worried that the timeline was unrealistic, given how many agencies would have to coordinate their efforts across three separate fiscal years.",
        "In the end, the chair suggested a compromise that nobody liked but everyone could tolerate; the vote passed narrowly, seven to six, after nearly four hours of debate.",
        "Supporters point to a 2019 pilot in which 91.4% of participants reported shorter waits, while opponents argue that the pilot's sites were not typical.",
        "Neither side expects a quick resolution, and both say they are preparing for a long autumn of hearings, amendments and, quite possibly, a court challenge.",
    ]

    /// About `minutes` of prose: paragraphs of the sample sentences, numbered so no two repeat exactly.
    private func article(minutes: Int) -> String {
        let paragraphs = (0..<(minutes * 5)).map { index in
            "Section \(index + 1). " + (0..<4).map { Self.prose[(index + $0) % Self.prose.count] }.joined(separator: " ")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    func testRendersASentenceAsAReadableWavWithTheKittenEngineTag() async throws {
        let renderer = try KittenNarrationRenderer(assets: Self.assets, outputDirectory: outputDirectory, governor: OnDeviceVoiceGovernor())
        let result = try await renderer.render(text: Self.prose[0])
        XCTAssertEqual(result.engine, "kitten")
        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertGreaterThan(result.duration, 5)
        XCTAssertLessThan(result.duration, 20)
        let file = try AVAudioFile(forReading: result.audioURL)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, result.duration, accuracy: 0.05)
        var diagnostics = await renderer.diagnostics()
        XCTAssertEqual(diagnostics.sessionLoadCount, 1)
        XCTAssertEqual(diagnostics.generatedFileCount, 1)
        await renderer.discardGeneratedAudio(at: URL(fileURLWithPath: "/tmp/not-mine.wav"))
        await renderer.discardGeneratedAudio(at: result.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.audioURL.path))
        diagnostics = await renderer.diagnostics()
        XCTAssertEqual(diagnostics.generatedFileCount, 0)
        await renderer.unload()
        _ = try await renderer.render(text: "Loads again after an unload.")
        diagnostics = await renderer.diagnostics()
        XCTAssertEqual(diagnostics.sessionLoadCount, 2)
    }

    func testEmptyAndPunctuationOnlyTextFailsWithoutCrashing() async throws {
        let renderer = try KittenNarrationRenderer(assets: Self.assets, outputDirectory: outputDirectory, governor: OnDeviceVoiceGovernor())
        do { _ = try await renderer.render(text: "  \n "); XCTFail("empty text must throw") } catch { XCTAssertEqual(error as? KittenNarrationError, .emptyText) }
        for text in ["...", "—", "42", "🎧", "A", "Mr. Dr. St. etc."] {
            if let result = try? await renderer.render(text: text) { XCTAssertGreaterThan(result.duration, 0.05, text) }
        }
    }

    func testMissingAssetsAreNamed() throws {
        let empty = KittenAssetLocation(rootURL: outputDirectory)
        XCTAssertThrowsError(try KittenNarrationRenderer(assets: empty, outputDirectory: outputDirectory, governor: OnDeviceVoiceGovernor())) {
            XCTAssertEqual($0 as? KittenNarrationError, .missingAsset("kitten_tts_nano_v0_8.onnx"))
        }
    }

    // #1679: heat hands narration to Kitten, and Kitten used to render flat out in the background, so iOS stopped the
    // app for its CPU use about a minute after the phone was locked. A backgrounded Kitten render now waits out the
    // rest its last inference earned, by the shared governor's rule, before the next inference; with the app in front
    // nothing waits.
    func testABackgroundedRenderWaitsBeforeTheNextInferenceAndAForegroundOneDoesNot() async throws {
        final class Slept: @unchecked Sendable {
            private let lock = NSLock()
            private var total: TimeInterval = 0
            var seconds: TimeInterval { lock.withLock { total } }
            func add(_ seconds: TimeInterval) { lock.withLock { total += seconds } }
        }
        // Real time for the inference; a rest moves the clock on without sleeping.
        let slept = Slept()
        let governor = OnDeviceVoiceGovernor(now: { ProcessInfo.processInfo.systemUptime + slept.seconds }, sleep: { slept.add($0) })
        let renderer = try KittenNarrationRenderer(assets: Self.assets, outputDirectory: outputDirectory, governor: governor)

        _ = try await renderer.render(text: Self.prose[0])
        _ = try await renderer.render(text: Self.prose[1])
        XCTAssertEqual(slept.seconds, 0, "with the app in front a render is not slowed down")

        governor.setAppBackgrounded(true)
        let background = try await renderer.render(text: Self.prose[2])
        let paced = try XCTUnwrap(governor.debugPacingRecords.last)
        XCTAssertGreaterThan(paced.delay, 0, "\(governor.debugPacingRecords)")
        XCTAssertGreaterThanOrEqual(paced.delay, paced.inference * (1 / OnDeviceInferencePacingPolicy.backgroundWorkDutyCycle - 1) - 0.000_1,
                                    "at least the wall-time rest Supertonic gets")
        XCTAssertEqual(slept.seconds, 0, "the chunk itself is handed back at once")
        _ = try await renderer.render(text: Self.prose[3])
        XCTAssertGreaterThan(slept.seconds, paced.delay * 0.8, "the next inference waited out the rest")
        XCTAssertLessThanOrEqual(slept.seconds, paced.delay + 0.000_1)
        XCTAssertLessThan(paced.inference + paced.delay, background.duration,
                          "paced, Kitten still renders faster than the chunk plays (#1673)")
    }

    /// A long article through the fallback voice, read as the player plans it (a short first chunk, then the
    /// article's own chunks), with each next chunk starting the moment the one before it ends or, when it
    /// isn't ready, when it is. No pause between chunks may pass 1 s. `SPEECH_SOAK_MINUTES` sets the length
    /// (30 for the full soak; 6 by default so the fast loop stays short). This is the renderer on the Mac: the
    /// phone's speed is the owner's Low Power Mode check, and the in-app wiring is `SupertonicSpeechTests`.
    ///
    /// Compute time, not wall time (#1648): a render's cost is the CPU time the process spent on it, which a busy Mac
    /// can't stretch the way it stretches the clock (the wall-clock version failed at load averages of 60 and up with
    /// the same code). The model runs on one thread here, so CPU time is what the render would take alone on a core;
    /// the app's two threads measured faster than one (C2 M2), so passing the bars on one is the stricter check.
    /// The wall-clock time is printed for the log and is not asserted.
    func testALongArticleThroughTheFallbackVoiceNeverPausesOverOneSecond() async throws {
        let minutes = Int(ProcessInfo.processInfo.environment["SPEECH_SOAK_MINUTES"] ?? "") ?? 6
        let text = article(minutes: minutes)
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: SpeechTextNormalizer.normalize(text), articleText: text, articleSpokenStart: 0)
        let chunks = NarrationChunkPlanner.splittingFirstChunk(
            of: spoken.chunks, spokenText: SpeechTextNormalizer.normalize(text), playheadOffset: 0)
        let renderer = try KittenNarrationRenderer(assets: Self.assets, outputDirectory: outputDirectory, threads: 1, governor: OnDeviceVoiceGovernor())

        var renderedChunks = 0, rendered = 0.0, wall = 0.0, audio = 0.0, ends = 0.0, longestPause = 0.0, firstReady = 0.0, memoryAfterFirst = 0.0, peak = 0.0
        for (index, chunk) in chunks.enumerated() {
            let started = Date(), cpuStarted = OnDeviceVoiceGovernor.processCPUTime()
            let result = try await renderer.render(text: chunk.text)
            wall += Date().timeIntervalSince(started)
            rendered += OnDeviceVoiceGovernor.processCPUTime() - cpuStarted
            audio += result.duration
            renderedChunks += 1
            // The player starts this chunk when the previous one ends, or when this one is ready.
            let begins = max(rendered, ends)
            if index == 0 { firstReady = rendered; memoryAfterFirst = residentMegabytes() } else { longestPause = max(longestPause, begins - ends) }
            ends = begins + result.duration
            peak = max(peak, residentMegabytes())
            await renderer.discardGeneratedAudio(at: result.audioURL)
            if audio >= Double(minutes) * 60 { break }
        }
        print(String(format: "SOAK %d min article: %.0f s of audio from %d chunks in %.0f s of compute (%.1fx; %.0f s on the clock, %.1fx), first audio after %.2f s, longest pause %.2f s, memory %.0f MB after the first chunk, peak %.0f MB",
                     minutes, audio, renderedChunks, rendered, audio / rendered, wall, audio / wall, firstReady, longestPause, memoryAfterFirst, peak))
        XCTAssertGreaterThan(rendered, 0, "the process CPU clock could not be read")
        XCTAssertGreaterThanOrEqual(audio, Double(minutes) * 60 * 0.95)
        XCTAssertLessThanOrEqual(longestPause, 1.0)
        XCTAssertGreaterThan(audio / rendered, 4, "the 4x bar from C2 M2")
        XCTAssertLessThan(peak - memoryAfterFirst, 500, "memory must not climb across a long article")
    }
}
