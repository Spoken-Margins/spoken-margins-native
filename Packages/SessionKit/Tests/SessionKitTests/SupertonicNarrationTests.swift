import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitSupertonic

final class SupertonicNarrationTests: XCTestCase {
    // The pacing policy's own tests are in SessionKitCoreTests/OnDeviceVoiceGovernorTests (#1679).

    // #377: live narration and background preparation share one renderer. Preparation used to
    // set the shared pacing flag for its render and clear it after, so a live chunk rendered in
    // the foreground meanwhile was paced, and a pass ending in the background switched pacing
    // off. Pacing is now per render: preparation always, live narration only in the background.
    func testPreparationPacingNeitherPacesLiveNarrationNorClearsBackgroundPacing() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-pacing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: assets.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        for file in [
            "duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx",
            "vocoder.onnx", "tts.json", "unicode_indexer.json"
        ] {
            _ = FileManager.default.createFile(atPath: assets.onnxDirectoryURL.appending(path: file).path, contents: Data())
        }
        for voice in SupertonicVoiceID.allCases {
            _ = FileManager.default.createFile(atPath: assets.voiceStyleURL(for: voice).path, contents: Data())
        }
        let renderer = try SupertonicNarrationRenderer(assets: assets, outputDirectory: root.appending(path: "output"), governor: OnDeviceVoiceGovernor())

        renderer.setBackgroundInferencePacingEnabled(false)
        XCTAssertGreaterThan(renderer.pacingDelay(afterInferenceDuration: 10, for: .always), 0,
                             "background preparation is paced in the foreground too")
        XCTAssertEqual(renderer.pacingDelay(afterInferenceDuration: 10, for: .whenAppBackgrounded), 0,
                       "foreground live narration isn't, even while preparation renders")

        renderer.setBackgroundInferencePacingEnabled(true)
        XCTAssertGreaterThan(renderer.pacingDelay(afterInferenceDuration: 10, for: .always), 0)
        XCTAssertGreaterThan(renderer.pacingDelay(afterInferenceDuration: 10, for: .whenAppBackgrounded), 0,
                             "live narration in the background stays paced after a preparation render")
    }

    // #379 audit: the test above checks the policy, not a render. Here real renders run through the
    // renderer: live narration in the foreground is never held back while a preparation render is
    // in flight, and a preparation render ending in the background leaves live narration paced.
    func testRealRendersArePacedByWhoAskedNotBySharedState() async throws {
        let model = try SupertonicTestModel.assets()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-real-pacing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = try SupertonicNarrationRenderer(assets: model, outputDirectory: root, governor: OnDeviceVoiceGovernor())
        func render(_ text: String, _ pacing: SupertonicRenderPacing) async throws {
            let result = try await renderer.render(text: text, voice: .m2, language: "en", speed: 1, synthesisSteps: 5, pacing: pacing)
            await renderer.discardGeneratedAudio(at: result.audioURL)
        }

        renderer.setBackgroundInferencePacingEnabled(false)
        async let preparation: Void = render("Background preparation renders this chunk.", .always)
        try await render("The listener hears this sentence now.", .whenAppBackgrounded)
        try await preparation
        let foreground = renderer.debugPacingRecords
        XCTAssertTrue(foreground.contains { $0.pacing == .always && $0.delay > 0 }, "preparation is paced: \(foreground)")
        XCTAssertTrue(foreground.contains { $0.pacing == .whenAppBackgrounded }, "the live render ran: \(foreground)")
        XCTAssertTrue(foreground.filter { $0.pacing == .whenAppBackgrounded }.allSatisfy { $0.delay == 0 },
                      "live narration in the foreground is never held back: \(foreground)")

        renderer.setBackgroundInferencePacingEnabled(true)
        try await render("Background preparation finishes a chunk.", .always)
        try await render("The listener keeps hearing narration.", .whenAppBackgrounded)
        let background = renderer.debugPacingRecords.dropFirst(foreground.count)
        let live = background.filter { $0.pacing == .whenAppBackgrounded }
        XCTAssertFalse(live.isEmpty)
        XCTAssertTrue(live.allSatisfy { $0.delay > 0 }, "live narration stays paced in the background: \(Array(background))")
    }

    // #2695: Supertonic's steps were timed by wall clock only, so the CPU its ONNX threads used was never charged.
    // Every step now goes through the governor's measure, which charges the shared background budget.
    func testARealRenderChargesItsCPUToTheSharedBudget() async throws {
        let model = try SupertonicTestModel.assets()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-budget-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let governor = OnDeviceVoiceGovernor()
        let renderer = try SupertonicNarrationRenderer(assets: model, outputDirectory: root, governor: governor)
        XCTAssertEqual(governor.budgetSpent(), 0)
        let result = try await renderer.render(
            text: "Background preparation renders this chunk.", voice: .m2, language: "en", speed: 1, synthesisSteps: 5, pacing: .always)
        await renderer.discardGeneratedAudio(at: result.audioURL)
        XCTAssertGreaterThan(governor.budgetSpent(), 0, "every inference step is charged")
    }

    // #2695 review: the real-model test above skips without the downloaded model, so in CI nothing proved Supertonic's
    // steps are charged. This drives the same step the renderer hands the model (`pacedInferenceStep`, through
    // `runPacedInference`) with stub steps whose CPU is twice their wall time, as two ONNX threads make it.
    func testEveryStubStepIsChargedItsCPUTimeToTheSharedBudget() throws {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0; var cpu: TimeInterval = 0 }
        let clock = Clock()
        let governor = OnDeviceVoiceGovernor(
            conditions: { SpeechEngineConditions(thermal: .fair) },
            now: { clock.now }, cpuTime: { clock.cpu }, sleep: { clock.now += $0 })
        let step = SupertonicNarrationRenderer.pacedInferenceStep(
            governor: governor, pacing: .whenAppBackgrounded, isCancelled: { false })
        // Duration, text encoder, five flow steps and the vocoder: eight model steps.
        var outputs: [Int] = []
        for index in 0..<8 {
            outputs.append(try runPacedInference(step) {
                clock.now += 0.25
                clock.cpu += 0.5
                return index
            })
        }
        XCTAssertEqual(outputs, Array(0..<8), "each step's result comes back through the pacing")
        XCTAssertEqual(governor.budgetSpent(), 8 * 0.5, accuracy: 1e-9, "charged CPU time, not wall time (2.0)")
        #if DEBUG
        XCTAssertEqual(governor.debugPacingRecords.count, 8, "every step is paced")
        #endif
    }

    // #586: the model leaves about 0.6 s of silence before the speech and 0.8 s after it, so every
    // chunk seam was a stall of more than a second. A real render has to come back trimmed to its
    // speech and a short pad, and say how much it cut so the output check still judges the model's
    // own duration.
    func testRealRenderComesBackTrimmedToItsSpeech() async throws {
        let model = try SupertonicTestModel.assets()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-real-trim-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = try SupertonicNarrationRenderer(assets: model, outputDirectory: root, governor: OnDeviceVoiceGovernor())
        let result = try await renderer.render(
            text: "The listener hears this sentence now.", voice: .m2, language: "en", speed: 1,
            synthesisSteps: 5, pacing: .whenAppBackgrounded
        )

        XCTAssertGreaterThan(result.trimmedSilence, 0.5, "the model's silence before and after the speech was cut")
        XCTAssertEqual(result.modelDuration, result.duration + result.trimmedSilence, accuracy: 0.000_001)

        // The file is a 44-byte header and 16-bit mono samples. Trimming it again finds nothing to cut.
        let file = try Data(contentsOf: result.audioURL)
        let samples = stride(from: 44, to: file.count - 1, by: 2).map { offset -> Float in
            Float(Int16(littleEndian: file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int16.self) })) / 32_767
        }
        XCTAssertEqual(Double(samples.count) / Double(result.sampleRate), result.duration, accuracy: 0.01)
        let window = Int(Double(result.sampleRate) * SpeechSilenceTrim.windowSeconds)
        let range = try XCTUnwrap(SpeechSilenceTrim.speechRange(in: samples, sampleRate: result.sampleRate))
        XCTAssertLessThanOrEqual(range.lowerBound, window, "the file starts at its leading pad")
        XCTAssertLessThanOrEqual(samples.count - range.upperBound, window, "the file ends at its trailing pad")
    }

    func testCanonicalVoiceIDsRoundTripWithoutDisplayNames() throws {
        XCTAssertEqual(SupertonicVoiceID.m2.rawValue, "M2")
        XCTAssertEqual(SupertonicVoiceID.f2.rawValue, "F2")
        XCTAssertEqual(Set(SupertonicVoiceID.allCases.map(\.rawValue)), [
            "F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"
        ])
        XCTAssertEqual(
            try JSONDecoder().decode(SupertonicVoiceID.self, from: Data(#""M2""#.utf8)),
            .m2
        )
    }

    func testAssetValidationRequiresModelsUnicodeConfigurationAndAllTenStyles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: assets.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        for file in [
            "duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx",
            "vocoder.onnx", "tts.json", "unicode_indexer.json"
        ] {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: assets.onnxDirectoryURL.appending(path: file).path,
                contents: Data([0])
            ))
        }
        for voice in SupertonicVoiceID.allCases {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: assets.voiceStyleURL(for: voice).path,
                contents: Data("{}".utf8)
            ))
        }

        XCTAssertNoThrow(try assets.validate())
        try FileManager.default.removeItem(at: assets.voiceStyleURL(for: .m5))
        XCTAssertThrowsError(try assets.validate()) { error in
            XCTAssertEqual(error as? SupertonicNarrationError, .missingAsset("voice_styles/M5.json"))
        }
    }

    func testRendererRejectsEmptyTextAndUnsupportedStepCountBeforeInference() async throws {
        // The public preconditions are tested with a minimal, structurally valid
        // asset tree; inference is never reached for either invalid request.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-invalid-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: assets.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        for file in [
            "duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx",
            "vocoder.onnx", "tts.json", "unicode_indexer.json"
        ] {
            _ = FileManager.default.createFile(atPath: assets.onnxDirectoryURL.appending(path: file).path, contents: Data())
        }
        for voice in SupertonicVoiceID.allCases {
            _ = FileManager.default.createFile(atPath: assets.voiceStyleURL(for: voice).path, contents: Data())
        }
        let renderer = try SupertonicNarrationRenderer(
            assets: assets,
            outputDirectory: root.appending(path: "output", directoryHint: .isDirectory),
            governor: OnDeviceVoiceGovernor()
        )

        do {
            _ = try await renderer.render(text: "  ")
            XCTFail("Expected empty text to be rejected")
        } catch {
            XCTAssertEqual(error as? SupertonicNarrationError, .emptyText)
        }
        do {
            _ = try await renderer.render(text: "Hello", synthesisSteps: 4)
            XCTFail("Expected invalid synthesis steps to be rejected")
        } catch {
            XCTAssertEqual(error as? SupertonicNarrationError, .invalidSynthesisSteps(4))
        }
    }

    // #258: the player hands the renderer files it didn't make (an article's durable prepared
    // chunks, disk-cache entries) to discard. Only the renderer's own output may be deleted.
    func testDiscardDeletesOnlyAudioTheRendererGenerated() async throws {
        let model = try SupertonicTestModel.assets()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = root.appending(path: "PreparedAudio/item/chunk-0001.wav")
        try FileManager.default.createDirectory(at: durable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("durable prepared chunk".utf8).write(to: durable)
        let renderer = try SupertonicNarrationRenderer(assets: model, outputDirectory: root.appending(path: "Playback"), governor: OnDeviceVoiceGovernor())

        await renderer.discardGeneratedAudio(at: durable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.path), "a prepared chunk the renderer didn't make survives")

        let generated = try await renderer.render(text: "A short sentence.", voice: .m2, speed: 1, synthesisSteps: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.audioURL.path))
        await renderer.discardGeneratedAudio(at: generated.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generated.audioURL.path), "its own output is still discarded")
        await renderer.unload()
    }
}
