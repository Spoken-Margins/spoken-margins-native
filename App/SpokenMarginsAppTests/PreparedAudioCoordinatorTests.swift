import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

final class PreparedAudioCoordinatorTests: XCTestCase {
    func testStreamingRenderIdentityMatchesLegacyBytesAndRehashesMutableAssets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: assets.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        let payloads = [("a.onnx", Data(repeating: 7, count: 150_000)), ("z.onnx", Data([8, 9]))]
        var legacy = Data()
        for (name, data) in payloads {
            try data.write(to: assets.onnxDirectoryURL.appending(path: name))
            legacy.append(Data(name.utf8)); legacy.append(0); legacy.append(data); legacy.append(0)
        }
        try Data([1, 2]).write(to: assets.voiceStyleURL(for: .m2))
        let before = try SupertonicRenderIdentity.make(assets: assets, voice: .m2)
        XCTAssertEqual(before.assetManifestHash, SupertonicRenderIdentity.sha256(legacy))
        try Data([9, 8]).write(to: assets.onnxDirectoryURL.appending(path: "z.onnx"))
        let after = try SupertonicRenderIdentity.make(assets: assets, voice: .m2)
        XCTAssertNotEqual(before.digest, after.digest, "Mutable assets must not use the immutable bundle cache")
    }

    func testChunkPlanCacheReusesOnlyExactSource() {
        let cache = PreparedChunkPlanCache()
        var builds = 0
        func value(_ source: String) -> [PreparedChunkPlan] {
            cache.value(for: source) {
                builds += 1
                return [.init(index: 0, startOffset: 0, sourceLength: source.count, text: source)]
            }
        }
        XCTAssertEqual(value("First"), value("First"))
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(value("Other").first?.text, "Other")
        XCTAssertEqual(builds, 2)
        _ = value("First")
        XCTAssertEqual(builds, 3, "Retain just the most recent document plan")
        cache.removeAll()
        _ = value("First")
        XCTAssertEqual(builds, 4, "Memory pressure releases the cached plan")
    }

    @MainActor
    func testChunkProgressUpdatesOnlyAffectedLibraryRowWithoutReloadingStorage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plans())
        let item = Item(id: "item", title: "PDF", mediaType: "pdf", text: "First chunk. Second chunk.", externalReference: nil, status: "ready")
        let model = Gate1AppModel()
        let unrelated = LibraryItemRow(id: "unrelated", title: "Preserved", status: "Ready", canDelete: true)
        model.libraryItems = [LibraryItemRow(id: item.id, title: item.title, status: "Ready", canDelete: true), unrelated]
        let job = AudioPreparationJob(id: "job", itemId: item.id, manifestId: manifest.id, policy: .explicit, requestedAt: Date())
        model.applyPreparedChunkProgress(item: item, manifest: manifest, remainingJobs: [job])
        XCTAssertEqual(model.libraryItems.count, 2)
        XCTAssertEqual(model.libraryItems[1], unrelated)
        XCTAssertEqual(model.libraryItems[0].offlineState, .preparing)
    }

    func testCommittedChunksSurviveCoordinatorReconstructionAndAreReused() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = plans()
        let first = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        _ = try await first.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1, 2, 3]), coordinator: first, fixture: fixture)
        try await commit(plan[1], data: Data([4, 5, 6]), coordinator: first, fixture: fixture)

        let reconstructed = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let manifest = try await reconstructed.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        XCTAssertEqual(manifest.committedChunkCount, 2)
        let firstChunk = try await reconstructed.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0])
        let secondChunk = try await reconstructed.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1])
        XCTAssertNotNil(firstChunk)
        XCTAssertNotNil(secondChunk)
        let artifact = fixture.prepared.appending(path: "complete.wav")
        try Data([1, 2, 3, 4, 5, 6]).write(to: artifact)
        try await reconstructed.complete(itemId: "item", signature: signature("one"), prepared: PreparedTextAudio(
            normalizedText: "First chunk. Second chunk.",
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: artifact.absoluteString, durationMs: 2_000),
            timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 2_000)
        ))
        try await reconstructed.retry(itemId: "item", signature: signature("one"))
        let reopened = try await reconstructed.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        XCTAssertEqual(reopened.state, .readyOffline)
        XCTAssertEqual(reopened.chunks, manifest.chunks)
        XCTAssertTrue(try fixture.store.loadAudioPreparationJobs().isEmpty, "Reopening/retrying compatible complete audio must not enqueue synthesis")
    }

    func testLivePlaybackCommitsWithoutCreatingSpeculativeJob() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan, schedulesJob: false)
        try await commit(plan[0], data: Data([1, 2, 3]), coordinator: coordinator, fixture: fixture)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.committedChunkCount, 1)
        XCTAssertTrue(try fixture.store.loadAudioPreparationJobs().isEmpty)
        let recovered = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0])
        XCTAssertNotNil(recovered)
    }

    func testIdentityMutationInvalidatesPriorManifestWithoutDeletingChunks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let original = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1]), coordinator: coordinator, fixture: fixture)
        _ = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("two"), plan: plan)

        let invalidated = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: original.id))
        XCTAssertEqual(invalidated.state, .needsRepreparation)
        XCTAssertEqual(invalidated.chunks.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.prepared.appending(path: invalidated.chunks[0].relativePath).path))
    }

    func testCorruptCommittedChunkIsRejectedAndMarksManifestForRepreparation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1, 2, 3]), coordinator: coordinator, fixture: fixture)
        let committed = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id)?.chunks.first)
        try Data([9]).write(to: fixture.prepared.appending(path: committed.relativePath), options: .atomic)

        let lookup = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0])
        XCTAssertNil(lookup)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.state, .needsRepreparation)
    }

    func testStopPersistsCancellationWithoutDiscardingEarlierCommits() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1]), coordinator: coordinator, fixture: fixture)
        try await coordinator.stop(itemId: "item", signature: signature("one"))

        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.state, .stopped)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.chunks.count, 1)
        XCTAssertEqual(try fixture.store.loadAudioPreparationJobs().first?.isCancelled, true)
        try await coordinator.retry(itemId: "item", signature: signature("one"))
        try await commit(plan[1], data: Data([2]), coordinator: coordinator, fixture: fixture)
        let resumed = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        XCTAssertEqual(resumed.chunks.map(\.index), [0, 1])
        let retained = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0])
        XCTAssertNotNil(retained)

    }

    private func commit(_ plan: PreparedChunkPlan, data: Data, coordinator: PreparedAudioCoordinator, fixture: Fixture) async throws {
        let input = fixture.root.appending(path: "input-\(plan.index).wav")
        try data.write(to: input)
        try await coordinator.commit(
            itemId: "item",
            signature: signature("one"),
            plan: plan,
            sourceText: "First chunk. Second chunk.",
            audioURL: input,
            durationMs: 1_000
        )
    }

    private func plans() -> [PreparedChunkPlan] {
        [
            PreparedChunkPlan(index: 0, startOffset: 0, sourceLength: 12, text: "First chunk."),
            PreparedChunkPlan(index: 1, startOffset: 13, sourceLength: 13, text: "Second chunk.")
        ]
    }

    private func signature(_ digest: String) -> TTSRenderSignature {
        TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "assets", voiceStyleHash: digest, synthesisParametersHash: "parameters", normalizationVersion: "normalization", chunkingVersion: "chunking", digest: digest)
    }

    private struct Fixture { let root: URL; let prepared: URL; let store: SQLiteSessionStore }
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "prepared-audio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, prepared: root.appending(path: "Prepared", directoryHint: .isDirectory), store: try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path))
    }
}
