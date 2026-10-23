import Foundation
import SessionKit
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

/// #1820: the app no longer bundles Supertonic's model. The resolver finds only a downloaded copy, and says nil
/// otherwise, which is what makes Kitten read.
final class SupertonicAssetResolverTests: XCTestCase {
    func testTheAppBundleHoldsNoSupertonicModelOnlyItsLicences() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundled = resources.appending(path: "Supertonic", directoryHint: .isDirectory)
        XCTAssertThrowsError(try SupertonicAssetLocation(rootURL: bundled).validate(), "no model in the app")
        for graph in ["duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx", "vocoder.onnx"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundled.appending(path: "onnx/\(graph)").path), graph)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.appending(path: "licenses/SUPERTONIC_MODEL_OPENRAIL-M.txt").path),
                      "the licence the catalog and Terms show stays in the app")
    }

    func testNothingDownloadedIsNilAndADownloadedCopyIsFound() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "resolver-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        XCTAssertNil(SupertonicAssetResolver.location(supportDirectory: support))

        let root = VoiceCatalogCoordinator.voicesRoot(supportDirectory: support)
            .appending(path: "\(SupertonicAssetResolver.catalogVoiceId)/3cadd1e_int8-2026-05-11", directoryHint: .isDirectory)
        let location = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: location.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: location.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        for name in ["duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx", "vocoder.onnx", "tts.json"] {
            try Data(name.utf8).write(to: location.onnxDirectoryURL.appending(path: name))
        }
        for voice in SupertonicVoiceID.allCases {
            try Data(voice.rawValue.utf8).write(to: location.voiceStyleURL(for: voice))
        }
        XCTAssertNil(SupertonicAssetResolver.location(supportDirectory: support), "an incomplete download is not used")
        try Data("unicode_indexer.json".utf8).write(to: location.onnxDirectoryURL.appending(path: "unicode_indexer.json"))
        let found = try XCTUnwrap(SupertonicAssetResolver.location(supportDirectory: support))
        XCTAssertEqual(found.rootURL.standardizedFileURL.path, root.standardizedFileURL.path)
    }
}
