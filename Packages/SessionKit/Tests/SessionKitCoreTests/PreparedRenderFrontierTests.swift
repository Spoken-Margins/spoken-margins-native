import Foundation
import SessionKit
import XCTest

/// How much of an item's prepared audio is really on disk (#1013, ported from the app's
/// `PlaybackQualityTests` with the same real temporary files).
final class PreparedRenderFrontierTests: XCTestCase {
    func testFrontierStopsAtMissingChunkAndRejectsStaleSourceOrVoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("chunk"))
        let signature = TTSRenderSignature(engine: "test", modelRevision: "1", assetManifestHash: "assets", voiceStyleHash: "voice", synthesisParametersHash: "params", normalizationVersion: "1", chunkingVersion: "1", digest: "signature")
        let text = "One.\n\nTwo."
        let chunk = PreparedAudioChunk(id: "c", index: 0, sourceRange: SourceLocator(documentId: "source", segmentId: "s", utf8Start: 0, utf8End: 4), relativePath: "chunk", byteCount: 1, checksumSHA256: "committed", durationMs: 1000)
        var manifest = PreparedAudioManifest(id: "m", itemId: "i", sourcePackageId: "source", signature: signature, state: .preparing, plannedChunkCount: 3, chunks: [chunk])
        func value(_ m: PreparedAudioManifest, source: String = "One.\n\nTwo.", expectedSignature: TTSRenderSignature? = nil) -> Double {
            PreparedRenderFrontier.fraction(manifest: m, signature: expectedSignature ?? signature, sourceText: source, canonicalSourceText: text, root: root)
        }
        XCTAssertEqual(value(manifest), 0.4, accuracy: 0.001)
        let restored = try JSONDecoder().decode(PreparedAudioManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(value(restored), 0.4, accuracy: 0.001)
        var later = chunk; later.index = 2; later.sourceRange.utf8Start = 6; later.sourceRange.utf8End = 10
        manifest.chunks.append(later)
        XCTAssertEqual(value(manifest), 0.4, "Out-of-order completion cannot bridge a missing chunk")
        XCTAssertEqual(value(manifest, source: "Changed!!!"), 0)
        var otherVoice = signature; otherVoice.voiceStyleHash = "different"
        XCTAssertEqual(value(manifest, expectedSignature: otherVoice), 0)
        manifest.state = .needsRepreparation
        XCTAssertEqual(value(manifest), 0)
        manifest.state = .preparing
        try FileManager.default.removeItem(at: root.appendingPathComponent("chunk"))
        XCTAssertEqual(value(manifest), 0)
        manifest.state = .readyOffline
        manifest.artifact = PreparedAudioArtifact(relativePath: "whole", byteCount: 2, checksumSHA256: "committed", durationMs: 3000)
        XCTAssertEqual(value(manifest), 0, "Missing complete audio must not appear prepared")
        try Data([1, 2]).write(to: root.appendingPathComponent("whole"))
        XCTAssertEqual(value(manifest), 1)
    }
}
