import XCTest
@testable import SessionKit

/// #281: Build 30 re-keyed prepared chunks (#240), so Build 29's chunk files are never read again.
final class PreparedChunkStalenessTests: XCTestCase {
    private let current = String(repeating: "c", count: 64)
    private let build29 = String(repeating: "b", count: 64)

    private func asset(_ id: String, _ path: String, integrity: OfflineAssetIntegrity = .valid,
                       category: OfflineAssetCategory = .preparedChunk, lastAccessed: TimeInterval = 100) -> OwnedOfflineAsset {
        OwnedOfflineAsset(id: id, category: category, relativePath: path, byteCount: 1_000, isReproducible: true,
                          integrity: integrity, lastAccessedAt: Date(timeIntervalSinceReferenceDate: lastAccessed))
    }

    func testChunksFromAnOlderSignatureBecomeStaleAndCurrentOnesAreLeftAlone() {
        let assets = [
            asset("old", "PreparedAudio/item-1/\(build29)/chunks/00000.wav"),
            asset("old-adopted", "PreparedAudio/item-1/\(build29)/chunks/00001.wav", category: .preparedAudio),
            asset("new", "PreparedAudio/item-1/\(current)/chunks/00000.wav"),
        ]
        let changed = OfflineStoragePlanner.preparedChunkStaleness(assets: assets, currentSignatureDigest: current)
        XCTAssertEqual(changed.map(\.id), ["old", "old-adopted"])
        XCTAssertEqual(Set(changed.map(\.integrity)), [.stale])
    }

    func testOnlyChunkFilesAreJudgedAndCorruptRowsStayCorrupt() {
        let assets = [
            asset("assembled", "PreparedAudio/item-1/\(build29)/full.m4a", category: .preparedAudio),
            asset("elsewhere", "PreparedSupertonicAudio/item-1/\(build29)/chunks/00000.wav", category: .preparedAudio),
            asset("cache", "RenderedSpeechCache/\(build29)/chunks/00000.wav"),
            asset("corrupt", "PreparedAudio/item-1/\(build29)/chunks/00002.wav", integrity: .corrupt),
            asset("podcast", "PodcastAudio/episode.mp3", category: .podcast),
        ]
        XCTAssertEqual(OfflineStoragePlanner.preparedChunkStaleness(assets: assets, currentSignatureDigest: current), [])
    }

    func testSwitchingBackMakesThoseChunksValidAgain() {
        // Another voice or speed changes the digest too; going back makes its chunks current again.
        let marked = asset("voice-a", "PreparedAudio/item-1/\(build29)/chunks/00000.wav", integrity: .stale)
        let changed = OfflineStoragePlanner.preparedChunkStaleness(assets: [marked], currentSignatureDigest: build29)
        XCTAssertEqual(changed.map(\.integrity), [.valid])
        XCTAssertEqual(OfflineStoragePlanner.preparedChunkStaleness(assets: changed, currentSignatureDigest: build29), [])
    }

    func testEvictionTakesTheOldChunksFirst() {
        // The old chunk was used more recently than the current one, and still goes first.
        let old = asset("old", "PreparedAudio/item-1/\(build29)/chunks/00000.wav", lastAccessed: 500)
        let new = asset("new", "PreparedAudio/item-2/\(current)/chunks/00000.wav", lastAccessed: 100)
        XCTAssertEqual(OfflineStoragePlanner.evictionPlan(requiredBytes: 1, assets: [old, new]).selectedAssetIds, ["new"])
        let marked = OfflineStoragePlanner.preparedChunkStaleness(assets: [old, new], currentSignatureDigest: current)
        XCTAssertEqual(OfflineStoragePlanner.evictionPlan(requiredBytes: 1, assets: marked + [new]).selectedAssetIds, ["old"])
    }
}
