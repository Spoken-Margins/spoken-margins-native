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
        let text = (1...12).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }.joined(separator: " ")
        try store.saveItem(Item(id: itemId, title: "Warm article", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let preparedRoot = support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Supertonic", directoryHint: .isDirectory)
        let signature = try SupertonicRenderIdentity.make(assets: SupertonicAssetLocation(rootURL: resources), voice: voice)
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertGreaterThanOrEqual(plan.count, 3)
        let manifest = try await PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
            .begin(itemId: itemId, sourceText: text, signature: signature, plan: plan, schedulesJob: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: preparedRoot.appending(path: itemId, directoryHint: .isDirectory)) }
        try store.saveAudioPreparationJob(AudioPreparationJob(id: "job-\(manifest.id)", itemId: itemId, manifestId: manifest.id, policy: .whileCharging))

        let template = try makeHeatTestWAV()
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = HeatTestRenderer(templateURL: template)
        let heat = HeatReading()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: heat.thermal) },
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
        return Fixture(root: root, prepared: root.appending(path: "Prepared", directoryHint: .isDirectory), store: try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path))
    }
}

@MainActor private final class HeatReading { var thermal = SpeechThermalLevel.nominal }

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
