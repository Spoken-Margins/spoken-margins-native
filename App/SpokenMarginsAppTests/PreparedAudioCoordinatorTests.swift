import AVFoundation
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

    // #1820: Supertonic is a download now, and an installed voice folder never changes in place, so its 145 MB are
    // hashed once per run like the bundle's were, not on every play and preparation pass.
    func testADownloadedVoiceFolderIsHashedOncePerRun() throws {
        let assets = try SupertonicTestAssets.installPlaceholderDownload(in: self)
        guard assets.rootURL.lastPathComponent == SupertonicTestAssets.placeholderVersion else {
            throw XCTSkip("a real Supertonic download is on this simulator, and this test edits the files it hashes")
        }
        let first = try SupertonicRenderIdentity.make(assets: assets, voice: .m2)
        let graph = assets.onnxDirectoryURL.appending(path: "vocoder.onnx")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: graph.path)[.size] as? Int)
        try Data(repeating: 0x2a, count: size).write(to: graph)  // an in-place edit the installer never makes
        let second = try SupertonicRenderIdentity.make(assets: assets, voice: .m2)
        XCTAssertEqual(first.assetManifestHash, second.assetManifestHash, "the model folder's hash came from the cache")
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

    @MainActor
    func testFinalChunkSnapshotCannotUndoPersistedOfflineCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "final-chunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "store.sqlite"))
        let store = try model.libraryStoreForTesting()
        let fixture = Fixture(root: root, prepared: root.appending(path: "Prepared"), store: store)
        addTeardownBlock { [weak model, weak store] in
            // Startup tasks can retain the connection after the test finishes.
            // Never unlink a live SQLite/WAL fixture.
            if model == nil, store == nil { try FileManager.default.removeItem(at: root) }
        }
        let item = Item(id: "final-item", title: "Finished PDF", mediaType: "pdf",
                        text: "First chunk. Second chunk.", externalReference: nil, status: "ready")
        try fixture.store.saveItem(item)
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let begun = try await coordinator.begin(itemId: item.id, sourceText: item.text!, signature: signature("one"), plan: plans())
        for plan in plans() {
            let file = fixture.root.appending(path: "chunk-\(plan.index).wav")
            try Data([1, 2, 3]).write(to: file)
            _ = try await coordinator.commit(itemId: item.id, signature: signature("one"), plan: plan,
                                             sourceText: item.text!, audioURL: file, durationMs: 1000)
        }
        let stale = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: begun.id))
        XCTAssertEqual(stale.state, .preparing)
        var complete = stale
        complete.state = .readyOffline
        complete.artifact = PreparedAudioArtifact(relativePath: "assembled.m4a", byteCount: 6,
                                                  checksumSHA256: "test", durationMs: 2000)
        try fixture.store.savePreparedAudioManifest(complete)
        model.libraryItems = [LibraryItemRow(id: item.id, title: item.title, status: "Ready", canDelete: true,
                                            offlineState: .readyOffline)]
        model.applyPreparedChunkProgress(item: item, manifest: stale, remainingJobs: [])
        XCTAssertEqual(model.libraryItems.first?.offlineState, .readyOffline)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: begun.id)?.state, .readyOffline)
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
        let firstChunk = try await reconstructed.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        let secondChunk = try await reconstructed.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1], sourceText: "First chunk. Second chunk.")
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

    func testCompletingNarrationOfTextTheItemNoLongerHasLeavesTheManifestUnready() async throws {
        // #344 audit on 4d7d41f: complete() hashes the assembled file before saving, and a
        // re-import can move the item to new text meanwhile; the manifest came back as ready.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plans())
        let artifact = fixture.root.appending(path: "complete.wav")
        try Data([1, 2, 3, 4, 5, 6]).write(to: artifact)
        let prepared = PreparedTextAudio(
            normalizedText: "First chunk. Second chunk.",
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: artifact.absoluteString, durationMs: 2_000),
            timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 2_000)
        )
        try fixture.store.saveItem(Item(id: "item", title: "PDF", mediaType: "pdf", text: "The upgraded text.", externalReference: nil, status: "ready"))
        try await coordinator.complete(itemId: "item", signature: signature("one"), prepared: prepared)
        XCTAssertNil(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.artifact)

        // With the text it was made from, the same call makes it ready.
        try fixture.store.saveItem(Item(id: "item", title: "PDF", mediaType: "pdf", text: "First chunk. Second chunk.", externalReference: nil, status: "ready"))
        try await coordinator.complete(itemId: "item", signature: signature("one"), prepared: prepared)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.state, .readyOffline)
    }

    func testNarrationFinishedAfterStopOrAVoiceChangeIsNotMarkedReady() async throws {
        // #2134: assembly runs for a while; a Stop or a new voice that landed meanwhile was overwritten
        // by complete(), which marked the old voice's audio ready.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let text = "First chunk. Second chunk."
        let artifact = fixture.root.appending(path: "complete.wav")
        try Data([1, 2, 3, 4, 5, 6]).write(to: artifact)
        let prepared = PreparedTextAudio(
            normalizedText: text,
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: artifact.absoluteString, durationMs: 2_000),
            timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 2_000)
        )

        let stopped = try await coordinator.begin(itemId: "item", sourceText: text, signature: signature("one"), plan: plans())
        try await coordinator.stop(itemId: "item", signature: signature("one"))
        let refusedAfterStop = try await coordinator.refusesCompletion(itemId: "item", signature: signature("one"))
        XCTAssertTrue(refusedAfterStop)
        let afterStop = try await coordinator.complete(itemId: "item", signature: signature("one"), prepared: prepared)
        XCTAssertFalse(afterStop)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: stopped.id)?.state, .stopped)
        XCTAssertNil(try fixture.store.loadPreparedAudioManifest(id: stopped.id)?.artifact)

        // A new voice retires the old one's manifest; the old assembly finishing must not revive it.
        _ = try await coordinator.begin(itemId: "item", sourceText: text, signature: signature("two"), plan: plans())
        let afterVoiceChange = try await coordinator.complete(itemId: "item", signature: signature("one"), prepared: prepared)
        XCTAssertFalse(afterVoiceChange)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: stopped.id)?.state, .needsRepreparation)
        XCTAssertNil(try fixture.store.loadPreparedAudioManifest(id: stopped.id)?.artifact)
    }

    func testAChunkRenderedFromTextTheItemNoLongerHasIsNotSaved() async throws {
        // #344 audit on 4d7d41f: commit() copies the chunk before saving, and a re-import
        // can move the item to new text meanwhile; the old text's chunk was saved anyway.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plans())
        try fixture.store.saveItem(Item(id: "item", title: "PDF", mediaType: "pdf", text: "The upgraded text.", externalReference: nil, status: "ready"))
        try await commit(plans()[0], data: Data([1, 2, 3]), coordinator: coordinator, fixture: fixture)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.chunks.count ?? 0, 0)
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
        let recovered = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
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

        let lookup = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        XCTAssertNil(lookup)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.state, .needsRepreparation)
    }

    /// APA-09: the old corruption wrote one byte over three, so the size check alone rejected it and the SHA-256
    /// comparison was never reached. Bit rot, or a file replaced by one of the same length, passes the size check.
    func testSameLengthCorruptionIsRejectedByTheChecksumAndMarksManifestForRepreparation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1, 2, 3]), coordinator: coordinator, fixture: fixture)
        let committed = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id)?.chunks.first)
        let url = fixture.prepared.appending(path: committed.relativePath)

        let intact = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        XCTAssertNotNil(intact, "control: the chunk as committed is served")

        try Data([9, 9, 9]).write(to: url, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: url).count, Int(committed.byteCount), "same length as what was committed")
        let lookup = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        XCTAssertNil(lookup)
        let marked = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        XCTAssertEqual(marked.state, .needsRepreparation)
        XCTAssertEqual(marked.failureCode, "chunk_checksum_mismatch")
    }

    /// APA-09: restarting a manifest keeps "only the chunks whose files are still intact". The old test lost a chunk by
    /// deleting its file; a chunk rewritten at the same length must be dropped too.
    func testBeginDropsAChunkRewrittenAtTheSameLengthAndKeepsTheIntactOne() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let source = "First chunk. Second chunk."
        _ = try await coordinator.begin(itemId: "item", sourceText: source, signature: signature("one"), plan: plans())
        for plan in plans() {
            let wav = fixture.root.appending(path: "chunk-\(plan.index).wav")
            try Data(repeating: UInt8(plan.index + 1), count: 64).write(to: wav)
            try await coordinator.commit(itemId: "item", signature: signature("one"), plan: plan,
                                         sourceText: source, audioURL: wav, durationMs: 1_000)
        }
        var manifest = try XCTUnwrap(try fixture.store.loadPreparedAudioManifests(itemId: "item").first)
        manifest.state = .readyOffline
        try fixture.store.savePreparedAudioManifest(manifest)
        try PreparedNarrationFallback.markPreparedAudioForRepreparation(itemId: "item", repository: fixture.store)
        let rotted = try XCTUnwrap(manifest.chunks.first { $0.index == 1 })
        try Data(repeating: 0xEE, count: Int(rotted.byteCount)).write(
            to: fixture.prepared.appending(path: rotted.relativePath), options: .atomic)

        let restarted = try await coordinator.begin(itemId: "item", sourceText: source, signature: signature("one"), plan: plans())

        XCTAssertEqual(restarted.state, .preparing)
        XCTAssertEqual(restarted.chunks.map(\.index), [0], "the chunk whose bytes changed is rendered again, the intact one kept")
    }

    // #312: lookups matched a committed chunk by index alone. When the plan for that index covers
    // a different stretch of the text, the saved audio is for other words and must not be played.
    // (A changed article is caught earlier, by the article plan's identity.)
    func testCommittedChunkForADifferentStretchOfTextIsNotReturned() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        _ = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[1], data: Data([1, 2, 3]), coordinator: coordinator, fixture: fixture)

        let shifted = PreparedChunkPlan(index: 1, startOffset: 12, sourceLength: 14, text: " Second chunk.")
        let lookup = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: shifted, sourceText: "First chunk. Second chunk.")
        XCTAssertNil(lookup, "audio saved for another stretch of the text does not match")
        let same = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1], sourceText: "First chunk. Second chunk.")
        XCTAssertNotNil(same, "the same stretch of the same text still matches")
    }

    // #312: background preparation counted any chunk at an index as done, and commit refused a
    // second chunk at that index. A chunk saved for other words was assembled into "ready offline"
    // audio and could never be replaced. Only matching chunks count, and commit replaces the rest.
    func testAChunkSavedForOtherWordsIsNotCountedAndIsReplaced() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let shifted = PreparedChunkPlan(index: 1, startOffset: 12, sourceLength: 14, text: " Second chunk.")
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1]), coordinator: coordinator, fixture: fixture)
        try await commit(shifted, data: Data([2]), coordinator: coordinator, fixture: fixture)

        let stale = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        XCTAssertEqual(stale.chunks.map(\.index), [0, 1])
        XCTAssertEqual(PreparedAudioCoordinator.matchingChunks(in: stale, plan: plan, sourceText: "First chunk. Second chunk.").map(\.index), [0],
                       "the chunk saved for other words does not count as prepared")

        try await commit(plan[1], data: Data([3, 4]), coordinator: coordinator, fixture: fixture)
        let replaced = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        XCTAssertEqual(PreparedAudioCoordinator.matchingChunks(in: replaced, plan: plan, sourceText: "First chunk. Second chunk.").map(\.index), [0, 1],
                       "committing the planned chunk replaces it")
        XCTAssertEqual(replaced.chunks.count, 2)
        let lookup = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1], sourceText: "First chunk. Second chunk.")
        XCTAssertEqual(lookup.map { try? Data(contentsOf: $0.audioURL) }, Data([3, 4]))
    }

    // #375 audit: a demand window's job ended once every index in it had some saved chunk, even
    // when those chunks were saved for other words. Only matching chunks make it prepared.
    func testADemandWindowOfChunksSavedForOtherWordsIsNotPrepared() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let manifest = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1]), coordinator: coordinator, fixture: fixture)
        try await commit(PreparedChunkPlan(index: 1, startOffset: 12, sourceLength: 14, text: " Second chunk."),
                         data: Data([2]), coordinator: coordinator, fixture: fixture)
        let saved = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        XCTAssertEqual(saved.chunks.map(\.index), [0, 1])
        XCTAssertTrue(PreparedAudioCoordinator.isPrepared(Array(plan.prefix(1)), in: saved, sourceText: "First chunk. Second chunk."))
        XCTAssertFalse(PreparedAudioCoordinator.isPrepared(plan, in: saved, sourceText: "First chunk. Second chunk."),
                       "chunk 1 was saved for other words")
    }

    // #375 audit: saved ranges hold offsets, not words. An edit that keeps every offset ("chunk"
    // to "chonk") matched the old audio. A manifest now records the article it was made from.
    func testAudioMadeFromOtherWordsAtTheSameOffsetsDoesNotMatch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let original = "First chunk. Second chunk.", edited = "First chunk. Second chonk."
        let manifest = try await coordinator.begin(itemId: "item", sourceText: original, signature: signature("one"), plan: plan)
        try await commit(plan[1], data: Data([1]), coordinator: coordinator, fixture: fixture)
        let saved = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))

        let stale = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1], sourceText: edited)
        XCTAssertNil(stale, "audio for the old words doesn't match the edited text")
        XCTAssertTrue(PreparedAudioCoordinator.matchingChunks(in: saved, plan: plan, sourceText: edited).isEmpty)
        let same = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1], sourceText: original)
        XCTAssertNotNil(same, "the unchanged text still matches")

        var editedItem = try fixture.store.loadItem(id: "item")
        editedItem.text = edited
        try fixture.store.saveItem(editedItem)
        let restarted = try await coordinator.begin(itemId: "item", sourceText: edited, signature: signature("one"), plan: plan)
        XCTAssertTrue(restarted.chunks.isEmpty, "preparing the edited text starts over")

        var legacy = saved
        legacy.articleIdentity = nil
        try fixture.store.savePreparedAudioManifest(legacy)
        let kept = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[1], sourceText: original)
        XCTAssertNotNil(kept, "a manifest from before #312 keeps the range check alone")
    }

    // #375 audit (Done when 2): assembly stitches the article plan's chunks, the same plan the
    // player's lookups and background preparation use (the player side is SupertonicSpeechTests).
    func testAssemblyChunksAreTheArticlePlan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let article = (1...8).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }
            .joined(separator: " ")
        let plan = PreparedChunkPlan.articlePlan(article)
        XCTAssertGreaterThan(plan.count, 1)
        var articleItem = try fixture.store.loadItem(id: "item")
        articleItem.text = article
        try fixture.store.saveItem(articleItem)
        _ = try await coordinator.begin(itemId: "item", sourceText: article, signature: signature("one"), plan: plan)
        for entry in plan {
            let input = fixture.root.appending(path: "input-\(entry.index).wav")
            try Data([UInt8(entry.index)]).write(to: input)
            try await coordinator.commit(itemId: "item", signature: signature("one"), plan: entry, sourceText: article, audioURL: input, durationMs: 1_000)
        }
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: "prepared-item-one"))
        let chunks = try PreparedAudioCoordinator.assemblyChunks(plan: plan, manifest: manifest, sourceText: article, preparedRoot: fixture.prepared)
        let articlePlan = NarrationChunkPlanner.articlePlan(article).chunks
        XCTAssertEqual(chunks.map(\.startOffset), articlePlan.map(\.startOffset))
        XCTAssertEqual(chunks.map(\.sourceLength), articlePlan.map(\.sourceLength))
        XCTAssertEqual(chunks.map(\.text), articlePlan.map(\.text))
        XCTAssertEqual(chunks.map(\.boundary), articlePlan.map(\.boundary))
        XCTAssertTrue(chunks.allSatisfy { FileManager.default.fileExists(atPath: $0.audioURL.path) })
    }

    // #645, the issue's case scaled down: a protected recording fills most of the budget and this
    // article's chunks are the only evictable files. Assembly reserves room for its output the size
    // of its inputs, which leaves a deficit. Before the fix that reservation evicted the chunks, the
    // assembler failed on the missing files, and every retry did the same. Now the reservation is
    // refused with the chunks kept, and once there's room the retry assembles them. Real WAVs,
    // SQLite, ledger and assembler, called in the order finishBackgroundPreparedAudio calls them.
    func testAssemblingNearTheLimitKeepsItsChunksAndSucceedsOnceThereIsRoom() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparedRoot = fixture.root.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.root)
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 1_000_000_000))
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: preparedRoot)
        let article = (1...8).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }
            .joined(separator: " ")
        let plan = PreparedChunkPlan.articlePlan(article)
        XCTAssertGreaterThan(plan.count, 1)
        // Preparation checks the stored item's text in its transaction, so the item holds the article.
        var articleItem = try fixture.store.loadItem(id: "item")
        articleItem.text = article
        try fixture.store.saveItem(articleItem)
        let manifestId = try await coordinator.begin(itemId: "item", sourceText: article, signature: signature("one"), plan: plan).id
        let template = try makeHeatTestWAV()
        defer { try? FileManager.default.removeItem(at: template) }
        for entry in plan {
            try await coordinator.commit(itemId: "item", signature: signature("one"), plan: entry, sourceText: article, audioURL: template, durationMs: 100)
            let committed = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifestId)?.chunks.first { $0.index == entry.index })
            let reservation = try await ledger.reserve(ownerId: "prepared-chunk-\(entry.index)", byteCount: committed.byteCount)
            try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                id: committed.id, itemId: "item", category: .preparedChunk, relativePath: "PreparedAudio/\(committed.relativePath)",
                byteCount: committed.byteCount, checksumSHA256: committed.checksumSHA256, isReproducible: true
            ))
        }
        let recording = fixture.root.appending(path: "Recordings/margin.m4a")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 200_000).write(to: recording)
        let recordingReservation = try await ledger.reserve(ownerId: "recording", byteCount: 200_000)
        try await ledger.commit(reservationId: recordingReservation.id, asset: OwnedOfflineAsset(
            id: "recording", category: .recording, relativePath: "Recordings/margin.m4a", byteCount: 200_000,
            isReproducible: false, protections: [.recording]
        ))
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifestId))
        let inputBytes = manifest.chunks.reduce(Int64(0)) { $0 + $1.byteCount }
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 200_000 + inputBytes + inputBytes / 2))

        func assemble() async throws -> PreparedTextAudio {
            let current = try await coordinator.droppingMissingChunks(manifestId: manifestId) ?? manifest
            let chunks = try PreparedAudioCoordinator.assemblyChunks(plan: plan, manifest: current, sourceText: article, preparedRoot: preparedRoot)
            let reservation = try await ledger.reserve(
                ownerId: "prepared-artifact-\(manifestId)", byteCount: inputBytes,
                pinning: PreparedAudioCoordinator.ledgerPaths(ofChunksIn: current)
            )
            do {
                let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                    itemId: "item", sourceText: article, projection: SpeechTextNormalizer.normalizeWithSourceOffsets(article),
                    voice: .m1, chunks: chunks, outputDirectory: fixture.root.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
                )
                try await ledger.release(reservationId: reservation.id)
                return prepared
            } catch {
                try? await ledger.release(reservationId: reservation.id)
                throw error
            }
        }

        do {
            _ = try await assemble()
            XCTFail("the only evictable files are the assembly's own inputs")
        } catch let error as OfflineStorageLedgerError {
            guard case .insufficientSpace = error else { return XCTFail("unexpected \(error)") }
            XCTAssertNotNil(error.errorDescription, "the pause says why: not enough offline storage")
        }
        for chunk in manifest.chunks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: preparedRoot.appending(path: chunk.relativePath).path), "chunk \(chunk.index) kept")
        }
        XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().filter { $0.category == .preparedChunk }.count, plan.count)
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifestId)?.chunks.count, plan.count, "nothing to render again")

        // Room is freed (the listener raises the limit): the retry assembles every chunk.
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 200_000 + inputBytes * 3))
        let prepared = try await assemble()
        let output = try XCTUnwrap(prepared.media.url.flatMap(URL.init(string:)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan(prepared.media.durationMs ?? 0, 0)
        XCTAssertGreaterThanOrEqual(prepared.timeline.segments.count, plan.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path), "the protected recording is never touched")
    }

    // #645: a chunk evicted or lost after it was committed was still counted as done, so every
    // retry went straight back to an assembly that failed on the missing file. The pass now
    // forgets it first, so it's rendered again.
    func testAChunkWhoseFileIsGoneIsRenderedAgainNotCountedAsDone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let source = "First chunk. Second chunk."
        let manifest = try await coordinator.begin(itemId: "item", sourceText: source, signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1]), coordinator: coordinator, fixture: fixture)
        try await commit(plan[1], data: Data([2, 2]), coordinator: coordinator, fixture: fixture)
        let committed = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        try FileManager.default.removeItem(at: fixture.prepared.appending(path: committed.chunks[1].relativePath))
        let job = try XCTUnwrap(fixture.store.loadAudioPreparationJobs().first)
        XCTAssertEqual(PreparedAudioCoordinator.completedIndexes(committed, plan: plan, sourceText: source, retryingStandInsFor: job), [0, 1],
                       "the saved record alone still counts the lost chunk")

        let swept = try await coordinator.droppingMissingChunks(manifestId: manifest.id)
        XCTAssertEqual(swept?.chunks.map(\.index), [0])
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.chunks.map(\.index), [0])
        XCTAssertEqual(PreparedAudioCoordinator.completedIndexes(try XCTUnwrap(swept), plan: plan, sourceText: source, retryingStandInsFor: job), [0])
        XCTAssertEqual(try fixture.store.loadAudioPreparationJobs().first?.nextChunkIndex, 1)

        try await commit(plan[1], data: Data([3, 3]), coordinator: coordinator, fixture: fixture)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifest(id: manifest.id)?.chunks.map(\.index), [0, 1])

        // Once assembled, chunks are meant to be evicted; a finished manifest's record is left alone.
        var ready = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: manifest.id))
        ready.state = .readyOffline
        try fixture.store.savePreparedAudioManifest(ready)
        try FileManager.default.removeItem(at: fixture.prepared.appending(path: ready.chunks[0].relativePath))
        let untouched = try await coordinator.droppingMissingChunks(manifestId: manifest.id)
        XCTAssertEqual(untouched?.chunks.map(\.index), [0, 1])
    }

    // #645 through the real preparation pass: near the limit, the next chunk's 64 MB reservation
    // evicted this article's earlier chunks. Now the pass pauses with the chunks kept, renders on
    // once there's room, and renders again a chunk whose file was lost since it was committed.
    @MainActor
    func testThePreparationPassNeverEvictsItsOwnChunksAndRendersALostOneAgain() async throws {
        let defaults = UserDefaults.standard
        // The guided-tour tombstone stops the startup tour download, whose reservation and evictable
        // file would change the ledger under the test's narrow budget (as in PasteAndGoTests).
        let keys = ["supertonicTTSMigrationV1", "supertonicVoicePendingTermsV1", "ttsMode", "ttsVoiceSelection",
                    SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey, "guidedOnboardingTombstone"]
        let prior = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        defer { for key in keys { if let value = prior[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        SpokenMarginsTerms.recordAcceptance()
        defaults.set(true, forKey: "guidedOnboardingTombstone")

        let root = FileManager.default.temporaryDirectory.appending(path: "self-evict-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "store.sqlite"))
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        model.ttsVoiceSelection = .james
        model.automaticAudioPreparationPolicy = .whileCharging
        let voice = try XCTUnwrap(model.ttsVoiceSelection.supertonicVoice)

        let itemId = "self-evict-\(UUID().uuidString)"
        let text = (1...36).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }.joined(separator: " ")
        try store.saveItem(Item(id: itemId, title: "Article near the limit", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let preparedRoot = support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let assets = try SupertonicTestAssets.installPlaceholderDownload(in: self) // the renderer is a stand-in (#1820)
        let signature = try SupertonicRenderIdentity.make(assets: assets, voice: voice)
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertGreaterThanOrEqual(plan.count, 5)
        let manifest = try await PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
            .begin(itemId: itemId, sourceText: text, signature: signature, plan: plan, schedulesJob: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: preparedRoot.appending(path: itemId, directoryHint: .isDirectory)) }
        let jobId = "job-\(manifest.id)"
        try store.saveAudioPreparationJob(AudioPreparationJob(id: jobId, itemId: itemId, manifestId: manifest.id, policy: .whileCharging))

        let template = try makeHeatTestWAV()
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = HeatTestRenderer(templateURL: template)
        model.preparationSeams = PreparationPassSeams(deviceConditions: { SpeechEngineConditions(thermal: .nominal) }, renderer: { renderer })
        func saved() throws -> PreparedAudioManifest { try XCTUnwrap(try store.loadPreparedAudioManifest(id: manifest.id)) }
        func chunkFile(_ index: Int) throws -> URL {
            preparedRoot.appending(path: try XCTUnwrap(try saved().chunks.first { $0.index == index }).relativePath)
        }

        _ = await model.performBackgroundAudioPreparationPass()
        _ = await model.performBackgroundAudioPreparationPass()
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1])
        let first = try chunkFile(0), second = try chunkFile(1)

        // Only this article's chunks may go: every other file the ledger knows is protected, and
        // the budget leaves the next chunk's reservation short by half of them.
        let ledger = try XCTUnwrap(model.offlineStorageLedger)
        let chunkPaths = PreparedAudioCoordinator.ledgerPaths(ofChunksIn: try saved())
        for asset in try store.loadOwnedOfflineAssets() where !chunkPaths.contains(asset.relativePath) {
            try await ledger.protect(assetId: asset.id, reason: .recentlyDeleted, enabled: true)
        }
        let chunkBytes = try saved().chunks.reduce(Int64(0)) { $0 + $1.byteCount }
        let used = try store.loadOwnedOfflineAssets().reduce(Int64(0)) { $0 + $1.byteCount }
            + store.loadOfflineStorageReservations().filter { $0.expiresAt > Date() }.reduce(Int64(0)) { $0 + $1.byteCount }
        try store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: used + 64 * 1_024 * 1_024 - chunkBytes / 2))

        _ = await model.performBackgroundAudioPreparationPass()
        var texts = await renderer.texts
        XCTAssertEqual(texts.count, 2, "no room for the next chunk, so nothing renders")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "chunk 0 is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "chunk 1 is kept")
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1])
        XCTAssertEqual(try store.loadAudioPreparationJobs().first { $0.id == jobId }?.lastFailureCode, "OfflineStorageLedgerError")

        // Room is freed: the pass renders on at chunk 2.
        try store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: used + 1_000_000_000))
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts, [plan[0].text, plan[1].text, plan[2].text])

        // A chunk's file is lost after it was committed: the next pass renders it again.
        try FileManager.default.removeItem(at: first)
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts.last, plan[0].text, "the lost chunk is rendered again, not counted as done")
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1, 2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try chunkFile(0).path))
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
        let retained = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        XCTAssertNotNil(retained)

    }

    private func commit(
        _ plan: PreparedChunkPlan, data: Data, coordinator: PreparedAudioCoordinator, fixture: Fixture, engine: String? = nil
    ) async throws {
        let input = fixture.root.appending(path: "input-\(plan.index).wav")
        try data.write(to: input)
        try await coordinator.commit(
            itemId: "item",
            signature: signature("one"),
            plan: plan,
            sourceText: "First chunk. Second chunk.",
            audioURL: input,
            durationMs: 1_000,
            engine: engine
        )
    }

    // #363 audit: a stand-in (the iOS voice) committed to prepared audio was found by every later
    // lookup and played as if it were Supertonic, and nothing could replace it. The player now
    // skips it and tries Supertonic again, whose chunk replaces the stand-in.
    func testAStandInChunkIsSkippedAndReplacedBySupertonic() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        _ = try await coordinator.begin(itemId: "item", sourceText: "First chunk. Second chunk.", signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([1]), coordinator: coordinator, fixture: fixture, engine: SupertonicNarrationResult.systemVoiceEngine)
        let standIn = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        XCTAssertNil(standIn, "the stand-in isn't played as Supertonic")

        try await commit(plan[0], data: Data([7, 7]), coordinator: coordinator, fixture: fixture, engine: SupertonicNarrationResult.systemVoiceEngine)
        try await commit(plan[0], data: Data([2, 3]), coordinator: coordinator, fixture: fixture, engine: "supertonic")
        let replaced = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: "First chunk. Second chunk.")
        XCTAssertEqual(replaced.flatMap { try? Data(contentsOf: $0.audioURL) }, Data([2, 3]), "Supertonic's chunk replaced it")
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: "prepared-item-one"))
        XCTAssertEqual(manifest.chunks.map(\.index), [0])
        XCTAssertNil(manifest.chunks.first?.engine)
        XCTAssertFalse(PreparedAudioCoordinator.hasStandIns(manifest), "nothing holds back assembly now")
        try await commit(plan[1], data: Data([4]), coordinator: coordinator, fixture: fixture, engine: SupertonicNarrationResult.systemVoiceEngine)
        let withStandIn = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: "prepared-item-one"))
        XCTAssertTrue(PreparedAudioCoordinator.hasStandIns(withStandIn), "a stand-in holds back assembly")

        // #363 audit: a listener's explicit request retries the stand-in with Supertonic once;
        // automatic preparation, and a request that already retried, don't.
        var job = AudioPreparationJob(id: "job", itemId: "item", manifestId: withStandIn.id, policy: .explicit, requestedAt: Date())
        XCTAssertEqual(PreparedAudioCoordinator.completedIndexes(withStandIn, plan: plan, sourceText: "First chunk. Second chunk.", retryingStandInsFor: job), [0])
        job.lastFailureCode = PreparedAudioCoordinator.standInRetried
        XCTAssertEqual(PreparedAudioCoordinator.completedIndexes(withStandIn, plan: plan, sourceText: "First chunk. Second chunk.", retryingStandInsFor: job), [0, 1])
        job = AudioPreparationJob(id: "job", itemId: "item", manifestId: withStandIn.id, policy: .whileCharging, requestedAt: Date())
        XCTAssertEqual(PreparedAudioCoordinator.completedIndexes(withStandIn, plan: plan, sourceText: "First chunk. Second chunk.", retryingStandInsFor: job), [0, 1])
    }

    // #1680: every Kitten chunk was committed and never read again, so each restart on a hot phone rendered the same
    // chunks from scratch. Its own engine finds the saved stand-in; Supertonic's lookup still never plays it (#363),
    // and Supertonic's chunk still replaces it.
    func testASavedKittenChunkIsFoundForKittenOnlyAndSupertonicStillReplacesIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = plans()
        let source = "First chunk. Second chunk."
        _ = try await coordinator.begin(itemId: "item", sourceText: source, signature: signature("one"), plan: plan)
        try await commit(plan[0], data: Data([5, 5]), coordinator: coordinator, fixture: fixture, engine: KittenNarrationRenderer.engine)

        let kitten = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: source,
                                                          engine: KittenNarrationRenderer.engine)
        XCTAssertEqual(kitten.flatMap { try? Data(contentsOf: $0.audioURL) }, Data([5, 5]), "Kitten's saved audio is found for Kitten")
        let asSupertonic = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: source)
        XCTAssertNil(asSupertonic, "and never played as Supertonic (#363)")
        let asSupertonicByName = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0],
                                                                      sourceText: source, engine: "supertonic")
        XCTAssertNil(asSupertonicByName)
        let asSystemVoice = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: source,
                                                                 engine: SupertonicNarrationResult.systemVoiceEngine)
        XCTAssertNil(asSystemVoice, "another stand-in engine doesn't match")
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: "prepared-item-one"))
        XCTAssertTrue(PreparedAudioCoordinator.hasStandIns(manifest), "it still holds back assembly")

        try await commit(plan[0], data: Data([2, 3]), coordinator: coordinator, fixture: fixture, engine: "supertonic")
        let replaced = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: source)
        XCTAssertEqual(replaced.flatMap { try? Data(contentsOf: $0.audioURL) }, Data([2, 3]), "Supertonic's chunk replaces it once allowed")
        let gone = try await coordinator.committedChunk(itemId: "item", signature: signature("one"), plan: plan[0], sourceText: source,
                                                        engine: KittenNarrationRenderer.engine)
        XCTAssertNil(gone)
    }

    // #278: Prepare on an article whose narration the fallback detached answered "already
    // available offline". A needs-repreparation manifest now restarts, keeping only intact chunks.
    func testBeginRestartsAManifestThatNeedsRepreparationKeepingIntactChunks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let source = "First chunk. Second chunk."
        _ = try await coordinator.begin(itemId: "item", sourceText: source, signature: signature("one"), plan: plans())
        for plan in plans() {
            let wav = fixture.root.appending(path: "chunk-\(plan.index).wav")
            try Data(repeating: UInt8(plan.index + 1), count: 64).write(to: wav)
            try await coordinator.commit(itemId: "item", signature: signature("one"), plan: plan,
                                         sourceText: source, audioURL: wav, durationMs: 1_000)
        }
        var manifest = try XCTUnwrap(try fixture.store.loadPreparedAudioManifests(itemId: "item").first)
        XCTAssertEqual(manifest.chunks.count, 2)
        manifest.state = .readyOffline
        try fixture.store.savePreparedAudioManifest(manifest)
        try PreparedNarrationFallback.markPreparedAudioForRepreparation(itemId: "item", repository: fixture.store)
        let lost = try XCTUnwrap(manifest.chunks.first { $0.index == 1 })
        try FileManager.default.removeItem(at: fixture.prepared.appending(path: lost.relativePath))

        let restarted = try await coordinator.begin(itemId: "item", sourceText: source, signature: signature("one"), plan: plans())

        XCTAssertEqual(restarted.state, .preparing, "prepared again, not reported as available offline")
        XCTAssertEqual(restarted.chunks.map(\.index), [0], "the intact chunk is kept, the lost one rendered again")
        XCTAssertNil(restarted.artifact)
    }

    /// #64 Done when 2, through the real preparation pass: heat pauses the job and saves
    /// "Paused for device temperature" with chunk 0 kept; once the phone cools, the pass resumes
    /// at chunk 1. Before #765 the pass returned early on heat and saved no pause.
    @MainActor
    func testHeatPausesThePreparationPassAndCoolingResumesAtTheNextChunk() async throws {
        let defaults = UserDefaults.standard
        let keys = ["supertonicTTSMigrationV1", "supertonicVoicePendingTermsV1", "ttsMode", "ttsVoiceSelection",
                    SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        defer { for key in keys { if let value = prior[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        SpokenMarginsTerms.recordAcceptance()

        let root = FileManager.default.temporaryDirectory.appending(path: "heat-pause-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "store.sqlite"))
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Startup tasks can retain the connection after the test finishes.
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        model.ttsVoiceSelection = .james
        model.automaticAudioPreparationPolicy = .whileCharging
        let voice = try XCTUnwrap(model.ttsVoiceSelection.supertonicVoice)
        XCTAssertTrue(model.hasAcceptedCurrentTerms)

        let itemId = "heat-item-\(UUID().uuidString)"
        let text = (1...36).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }.joined(separator: " ")
        try store.saveItem(Item(id: itemId, title: "Warm article", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let preparedRoot = support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let assets = try SupertonicTestAssets.installPlaceholderDownload(in: self) // the renderer is a stand-in (#1820)
        let signature = try SupertonicRenderIdentity.make(assets: assets, voice: voice)
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertGreaterThanOrEqual(plan.count, 5)
        let manifest = try await PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
            .begin(itemId: itemId, sourceText: text, signature: signature, plan: plan, schedulesJob: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: preparedRoot.appending(path: itemId, directoryHint: .isDirectory)) }
        try store.saveAudioPreparationJob(AudioPreparationJob(id: "job-\(manifest.id)", itemId: itemId, manifestId: manifest.id, policy: .whileCharging))

        let template = try makeHeatTestWAV()
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = HeatTestRenderer(templateURL: template)
        let heat = HeatReading()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: heat.read()) },
            renderer: { renderer }
        )
        func saved() throws -> PreparedAudioManifest { try XCTUnwrap(try store.loadPreparedAudioManifest(id: manifest.id)) }

        // Cool: the pass renders chunk 0.
        _ = await model.performBackgroundAudioPreparationPass()
        var texts = await renderer.texts
        XCTAssertEqual(texts, [plan[0].text])
        let first = try XCTUnwrap(try saved().chunks.first { $0.index == 0 })
        XCTAssertEqual(try saved().state, .preparing)

        // Hot: nothing renders, the manifest is saved as paused for heat, and chunk 0 stays.
        heat.thermal = .serious
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts.count, 1, "nothing renders while the phone is hot")
        XCTAssertEqual(try saved().state, .pausedForThermal)
        XCTAssertEqual(try saved().chunks.map(\.index), [0], "a heat pause keeps committed chunks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedRoot.appending(path: first.relativePath).path))
        XCTAssertEqual(try store.loadAudioPreparationJobs().map(\.id), ["job-\(manifest.id)"], "the job stays in line")

        // Cool again: the pass resumes at chunk 1, not chunk 0.
        heat.thermal = .nominal
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts, [plan[0].text, plan[1].text])
        XCTAssertEqual(try saved().state, .preparing)
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1])
        XCTAssertEqual(try saved().chunks.first { $0.index == 0 }?.checksumSHA256, first.checksumSHA256)

        // Cool when the pass starts, hot by the time it would render (Codex audit on 27fd1bd): the
        // pass reads the heat again just before rendering, so chunk 2 waits and the pause is saved.
        heat.warmsAfterReads = 1
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts.count, 2, "heat that rises during setup still stops the render")
        XCTAssertEqual(try saved().state, .pausedForThermal)
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1])

        // Cool again: chunk 2 renders.
        heat.thermal = .nominal
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(try saved().state, .preparing)

        // Playback commits a chunk while the pass sets up, then the phone gets hot (Codex audit on
        // bae0dc4): the pause is saved on the current manifest, so that chunk isn't lost.
        heat.warmsAfterReads = 1
        heat.onWarm = {
            guard var current = try? store.loadPreparedAudioManifest(id: manifest.id), var extra = current.chunks.first else { return }
            extra.id = "\(manifest.id)-chunk-3"
            extra.index = 3
            current.chunks.append(extra)
            try? store.savePreparedAudioManifest(current)
        }
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts.count, 3, "nothing renders once the phone is hot")
        XCTAssertEqual(try saved().state, .pausedForThermal)
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1, 2, 3], "a chunk committed during setup survives the pause")

        // Cool through setup, hot only once space is reserved and the renderer is ready (Codex audit
        // on e5088b9): the last check before rendering stops the next chunk and saves the pause again.
        heat.thermal = .nominal
        heat.warmsAfterReads = 2
        _ = await model.performBackgroundAudioPreparationPass()
        texts = await renderer.texts
        XCTAssertEqual(texts.count, 3, "heat that rises while the render is set up still stops it")
        XCTAssertEqual(try saved().state, .pausedForThermal)
        XCTAssertEqual(try saved().chunks.map(\.index), [0, 1, 2, 3])
        XCTAssertNil(heat.warmsAfterReads, "the pass read the heat a third time, right before rendering")
    }

    private func makeHeatTestWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "heat-template-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
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
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        try store.saveItem(Item(id: "item", title: "Paper", mediaType: "pdf", text: "First chunk. Second chunk.", externalReference: nil, status: "ready"))
        return Fixture(root: root, prepared: root.appending(path: "Prepared", directoryHint: .isDirectory), store: store)
    }
}

@MainActor private final class HeatReading {
    var thermal = SpeechThermalLevel.nominal
    /// Serious heat after this many more reads, as if the phone warmed up while the pass set up.
    var warmsAfterReads: Int?
    /// Runs as the heat arrives, standing in for work that lands while the pass sets up.
    var onWarm: (() -> Void)?

    func read() -> SpeechThermalLevel {
        if let reads = warmsAfterReads {
            if reads == 0 { thermal = .serious; warmsAfterReads = nil; onWarm?(); onWarm = nil } else { warmsAfterReads = reads - 1 }
        }
        return thermal
    }
}

/// Copies a short WAV for each chunk and reports a duration the output check accepts, so the
/// preparation pass commits it as Supertonic audio without loading the model.
private actor HeatTestRenderer: SupertonicRendering {
    let templateURL: URL
    private(set) var texts: [String] = []
    private var generated: Set<URL> = []

    init(templateURL: URL) { self.templateURL = templateURL }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        texts.append(text)
        let url = FileManager.default.temporaryDirectory.appending(path: "heat-render-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        generated.insert(url)
        return SupertonicNarrationResult(audioURL: url, duration: Double(text.count) / 15, sampleRate: 44_100,
                                         renderDuration: 0.01, sessionLoadCount: 1)
    }

    func discardGeneratedAudio(at url: URL) async {
        if generated.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }
}
