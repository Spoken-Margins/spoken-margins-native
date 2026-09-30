import Foundation
import XCTest
@testable import SessionKitSupertonic

final class SupertonicNarrationTests: XCTestCase {
    func testBackgroundInferencePacingLeavesSafetyMarginBelowIOSCPUQuota() {
        XCTAssertEqual(
            SupertonicInferencePacingPolicy.delay(afterInferenceDuration: 10, backgrounded: false),
            0
        )
        let delay = SupertonicInferencePacingPolicy.delay(
            afterInferenceDuration: 10,
            backgrounded: true
        )
        XCTAssertEqual(delay, 5.384615, accuracy: 0.000_001)
        XCTAssertEqual(10 / (10 + delay), 0.65, accuracy: 0.000_001)
    }

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
        let renderer = try SupertonicNarrationRenderer(assets: assets, outputDirectory: root.appending(path: "output"))

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
            outputDirectory: root.appending(path: "output", directoryHint: .isDirectory)
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
        let repoAssets = SupertonicAssetLocation(rootURL: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/SpokenMarginsApp/Resources/Supertonic", directoryHint: .isDirectory))
        guard (try? repoAssets.validate()) != nil else { throw XCTSkip("Supertonic assets not in this checkout") }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = root.appending(path: "PreparedAudio/item/chunk-0001.wav")
        try FileManager.default.createDirectory(at: durable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("durable prepared chunk".utf8).write(to: durable)
        let renderer = try SupertonicNarrationRenderer(assets: repoAssets, outputDirectory: root.appending(path: "Playback"))

        await renderer.discardGeneratedAudio(at: durable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.path), "a prepared chunk the renderer didn't make survives")

        let generated = try await renderer.render(text: "A short sentence.", voice: .m2, speed: 1, synthesisSteps: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.audioURL.path))
        await renderer.discardGeneratedAudio(at: generated.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generated.audioURL.path), "its own output is still discarded")
        await renderer.unload()
    }
}
