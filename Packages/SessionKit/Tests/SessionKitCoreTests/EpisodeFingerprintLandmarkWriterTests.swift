import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #2781: the landmark save moved off the main thread. It runs on the writer's actor, on a real SQLite Library and
/// real folders, one save at a time.
final class EpisodeFingerprintLandmarkWriterTests: XCTestCase {
    private var root: URL!
    private var mapsDirectory: URL!
    private var store: SQLiteSessionStore!
    private var writer: EpisodeFingerprintLandmarkWriter!
    private let itemId = "item-source-v2-abc"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("landmark-writer-\(UUID().uuidString)", isDirectory: true)
        mapsDirectory = root.appendingPathComponent("SpokenMargins/EpisodeMaps", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        writer = EpisodeFingerprintLandmarkWriter(store: store, episodeMapsDirectory: mapsDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func capture(
        start: Int,
        epoch: Int,
        grid: Int? = nil,
        trigger: EpisodeFingerprintTrigger = .stablePostSeek
    ) -> EpisodeFingerprintLandmarkInput {
        EpisodeFingerprintLandmarkInput(
            itemId: itemId,
            sourceMediaStartMs: start,
            sourceMediaEndMs: start + 11_000,
            anchorMediaTimeMs: start,
            continuityEpoch: epoch,
            gridIndex: grid,
            trigger: trigger,
            signatureData: Data(repeating: 7, count: 64)
        )
    }

    private func spine() throws -> EditionFingerprintSpineArtifact? {
        try store.loadEditionFingerprintSpine(itemId: itemId)
    }

    private func signatureFiles() throws -> [String] {
        let folder = mapsDirectory.appendingPathComponent(PodcastAnchorEvidencePaths.safeComponent(itemId), isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testALandmarkIsSavedWithItsFileAndOfflineAssetRow() async throws {
        let outcome = try await writer.write(capture(start: 120_000, epoch: 1))

        XCTAssertEqual(outcome, .init(keptNew: true, removedCount: 0))
        XCTAssertEqual(try spine()?.landmarks.map(\.continuityEpoch), [1])
        XCTAssertEqual(try signatureFiles().count, 1)
        let assets = try store.loadOwnedOfflineAssets()
        XCTAssertEqual(assets.map(\.category), [.fingerprintMap])
        XCTAssertEqual(assets.first?.byteCount, 64)
    }

    /// A grid landmark and a post-seek one are cut close together. Each save reads the spine and writes it back, so
    /// without one-at-a-time saves each would write a spine that lacks the other.
    func testLandmarksCutTogetherAreAllKept() async throws {
        let writer = self.writer!
        let inputs = [
            capture(start: 60_000, epoch: 0, grid: 0, trigger: .initialPlayback),
            capture(start: 360_000, epoch: 0, grid: 1, trigger: .periodicPlayback),
            capture(start: 900_000, epoch: 2),
            capture(start: 1_500_000, epoch: 3),
        ]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for input in inputs { group.addTask { try await writer.write(input) } }
            try await group.waitForAll()
        }

        XCTAssertEqual(try spine()?.landmarks.count, inputs.count)
        XCTAssertEqual(try signatureFiles().count, inputs.count)
        XCTAssertEqual(try store.loadOwnedOfflineAssets().count, inputs.count)
    }

    /// Build 35 left a spine with a post-seek landmark per audio buffer (#2626). The first save trims it, and the
    /// files and rows of what it drops go with them.
    func testTheFirstSaveCompactsABloatedSpineAndForgetsWhatItDropped() async throws {
        let safeItem = PodcastAnchorEvidencePaths.safeComponent(itemId)
        let folder = mapsDirectory.appendingPathComponent(safeItem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var landmarks: [EpisodeFingerprintLandmark] = []
        for index in 0..<400 {
            let start = 100_000 + index * 500
            let assetID = "episode-signature-\(safeItem)-epoch-1-\(start)"
            landmarks.append(EpisodeFingerprintLandmark(
                id: "landmark-epoch-1-\(start)", order: index, sourceMediaStartMs: start, sourceMediaEndMs: start + 11_000,
                anchorMediaTimeMs: start, continuityEpoch: 1, trigger: .stablePostSeek,
                provenance: .observedDecodedPlayback, signatureAssetId: assetID))
            try Data(count: 8).write(to: folder.appendingPathComponent("\(assetID).shazamsignature"))
            try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
                id: assetID, itemId: itemId, category: .fingerprintMap,
                relativePath: "SpokenMargins/EpisodeMaps/\(safeItem)/\(assetID).shazamsignature",
                byteCount: 8, isReproducible: false))
        }
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: "episode-spine-\(safeItem)", itemId: itemId, canonicalURL: nil, producingEditionDurationMs: nil,
            producingEditionSHA256: nil, createdAt: Date(), landmarks: landmarks))

        let outcome = try await writer.write(capture(start: 60_000, epoch: 0, grid: 0, trigger: .initialPlayback))

        let kept = try XCTUnwrap(try spine()?.landmarks)
        XCTAssertTrue(outcome.keptNew)
        XCTAssertLessThan(kept.count, 10, "200 s of landmarks fall to about one per minute, plus the new one")
        XCTAssertEqual(outcome.removedCount, 400 + 1 - kept.count)
        XCTAssertEqual(try signatureFiles().count, kept.count)
        XCTAssertEqual(try store.loadOwnedOfflineAssets().count, kept.count)
    }

    func testASecondPostSeekLandmarkOfTheSameEpochRightAfterIsRefusedAndWritesNoFile() async throws {
        try await writer.write(capture(start: 120_000, epoch: 1))

        let outcome = try await writer.write(capture(start: 120_500, epoch: 1))

        XCTAssertEqual(outcome, .init(keptNew: false, removedCount: 0))
        XCTAssertEqual(try spine()?.landmarks.count, 1)
        XCTAssertEqual(try signatureFiles().count, 1)
        XCTAssertEqual(try store.loadOwnedOfflineAssets().count, 1)
    }

    func testTheSameEpochAtAnotherPlaceInTheEpisodeIsKept() async throws {
        try await writer.write(capture(start: 120_000, epoch: 1))
        try await writer.write(capture(start: 1_200_000, epoch: 1))

        XCTAssertEqual(try spine()?.landmarks.count, 2)
    }
}
