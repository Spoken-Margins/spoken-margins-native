import SessionKit
import SessionKitPersistence
import XCTest

/// The playback frontier poll wakes on this signal (#2652), so every manifest writer must move it.
final class PreparedAudioChangeSignalTests: XCTestCase {
    func testSavingAndDeletingAManifestMovesTheSignal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "signal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let manifest = PreparedAudioManifest(
            id: "m", itemId: "item", sourcePackageId: "source",
            signature: TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                                          synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"),
            state: .preparing, plannedChunkCount: 1, chunks: [])
        let shared = PreparedAudioChangeSignal.shared
        let before = shared.generation
        try store.savePreparedAudioManifest(manifest)
        let afterSave = shared.generation
        XCTAssertGreaterThan(afterSave, before)
        try store.deletePreparedAudioManifest(id: "m")
        XCTAssertGreaterThan(shared.generation, afterSave)
        let memory = InMemorySessionRepository()
        let beforeMemory = shared.generation
        try memory.savePreparedAudioManifest(manifest)
        try memory.deletePreparedAudioManifest(id: "m")
        XCTAssertGreaterThan(shared.generation, beforeMemory)
    }
}
