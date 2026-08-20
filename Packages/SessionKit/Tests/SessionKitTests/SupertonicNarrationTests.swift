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
}
