import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #311: a prepared chunk records the engine that made it when that isn't the manifest's own,
/// so an iOS-voice stand-in for a garbled Supertonic chunk doesn't pass for Supertonic.
final class PreparedChunkEngineTests: XCTestCase {
    private func manifest(chunkEngine: String?) -> PreparedAudioManifest {
        PreparedAudioManifest(
            id: "prepared-item-engine", itemId: "item", sourcePackageId: "source",
            signature: TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                                          synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"),
            state: .preparing, plannedChunkCount: 1,
            chunks: [PreparedAudioChunk(
                id: "chunk-0", index: 0,
                sourceRange: SourceLocator(documentId: "source", segmentId: "chunk-0", utf8Start: 0, utf8End: 10),
                relativePath: "item/d/chunks/00000.wav", byteCount: 10, checksumSHA256: "x", durationMs: 1_000,
                engine: chunkEngine
            )]
        )
    }

    func testChunkEngineSurvivesTheStoreAndAChunkWithoutOneReadsAsNil() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chunk-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        try store.savePreparedAudioManifest(manifest(chunkEngine: "system_voice"))
        XCTAssertEqual(try store.loadPreparedAudioManifest(id: "prepared-item-engine")?.chunks.first?.engine, "system_voice")

        // A chunk with no engine field reads as nil. This is this build's own encoding with the key removed, not
        // a Build 29 chunk (PreparedAudioBuild29Tests reads those with Build 29's frozen model), and "the
        // manifest's engine" is chosen where the chunk is used, not here.
        let encoded = try JSONEncoder().encode(manifest(chunkEngine: nil).chunks[0])
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["engine"], "nil isn't written, so the stored shape is unchanged for Supertonic chunks")
        object.removeValue(forKey: "engine")
        let older = try JSONDecoder().decode(PreparedAudioChunk.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.engine)
    }
}
