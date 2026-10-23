import Foundation
import SessionKit
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

/// Supertonic's files for the app's tests. The model is a download and no longer in the app (#1820), so a test
/// either installs placeholders where the app finds a downloaded voice (when its renderer is a stand-in), or reads
/// the real model through the same named input as the package tests, and skips naming it when it's absent.
enum SupertonicTestAssets {
    /// The version folder the placeholders go in, so a test can tell them from a real download.
    static let placeholderVersion = "test-placeholder"

    /// Placeholder files laid out as a downloaded Supertonic, installed where `SupertonicAssetResolver` looks, for
    /// tests whose renderer is a stand-in: they need the files to exist and hash (the render identity), not to run.
    /// Removed at the test's teardown. A real download already on the simulator is used as it is and left alone.
    @discardableResult
    static func installPlaceholderDownload(in testCase: XCTestCase) throws -> SupertonicAssetLocation {
        if let existing = SupertonicAssetResolver.location() { return existing }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let voiceFolder = VoiceCatalogCoordinator.voicesRoot(supportDirectory: support)
            .appending(path: SupertonicAssetResolver.catalogVoiceId, directoryHint: .isDirectory)
        let root = voiceFolder.appending(path: placeholderVersion, directoryHint: .isDirectory)
        let location = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: location.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: location.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        for name in ["duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx", "vocoder.onnx", "tts.json", "unicode_indexer.json"] {
            try Data("placeholder \(name)".utf8).write(to: location.onnxDirectoryURL.appending(path: name))
        }
        for voice in SupertonicVoiceID.allCases {
            try Data("placeholder \(voice.rawValue)".utf8).write(to: location.voiceStyleURL(for: voice))
        }
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: voiceFolder) }
        let found = try XCTUnwrap(SupertonicAssetResolver.location(), "the app finds the placeholder download")
        XCTAssertEqual(found.rootURL.standardizedFileURL.path, root.standardizedFileURL.path)
        return found
    }

    /// The real model: `SESSIONKIT_SUPERTONIC_DIR` (give it to the app's tests as `TEST_RUNNER_SESSIONKIT_SUPERTONIC_DIR`),
    /// else this checkout's `artifacts/voice-catalog/files/supertonic-3-int8`, which
    /// `scripts/voice-catalog fetch supertonic-3-int8` writes. The simulator reads the Mac's files by path.
    static func realModel() throws -> SupertonicAssetLocation {
        let override = ProcessInfo.processInfo.environment["SESSIONKIT_SUPERTONIC_DIR"] ?? ""
        let folder = override.isEmpty
            ? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // SpokenMarginsAppTests
                .deletingLastPathComponent()  // App
                .deletingLastPathComponent()  // the checkout
                .appending(path: "artifacts/voice-catalog/files/supertonic-3-int8", directoryHint: .isDirectory)
            : URL(fileURLWithPath: override, isDirectory: true)
        let location = SupertonicAssetLocation(rootURL: folder)
        let graph = location.onnxDirectoryURL.appending(path: "vector_estimator.onnx")
        let size = (try? FileManager.default.attributesOfItem(atPath: graph.path)[.size] as? Int) ?? 0
        guard size > 1_000_000, (try? location.validate()) != nil else {
            throw XCTSkip("needs supertonicModel (\(folder.path)): Supertonic's model is a download, not in the app (#1820). "
                + "Run `scripts/voice-catalog fetch supertonic-3-int8` in the checkout, or set TEST_RUNNER_SESSIONKIT_SUPERTONIC_DIR")
        }
        return location
    }
}
