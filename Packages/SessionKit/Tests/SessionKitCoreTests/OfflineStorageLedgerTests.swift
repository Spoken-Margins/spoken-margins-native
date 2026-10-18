import Foundation
import XCTest
@testable import SessionKit

/// The offline storage ledger over an in-memory repository and a temporary directory (moved from the
/// app-hosted tests, #318). The tests that need the app's model, importers, download coordinator or the
/// real rendered-speech cache are in the app's OfflineStorageLedgerAppTests.
final class OfflineStorageLedgerTests: XCTestCase {
    func testReservationPreventsWriterFromExceedingBudget() async throws {
        let fixture = try makeFixture(limit: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.ledger.reserve(ownerId: "first", byteCount: 8)
        do {
            _ = try await fixture.ledger.reserve(ownerId: "second", byteCount: 3)
            XCTFail("Expected insufficient space")
        } catch let error as OfflineStorageLedgerError {
            XCTAssertEqual(error, .insufficientSpace(requiredBytes: 3, availableBytes: 2))
        }
    }

    func testCommitAcceptsALargerFileWhenTheBudgetHasRoom() async throws {
        // An ad-inserted episode came back 37 MB after HEAD reported 31 MB, and the download was discarded.
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reservation = try await fixture.ledger.reserve(ownerId: "writer", byteCount: 4)
        try await fixture.ledger.commit(
            reservationId: reservation.id,
            asset: OwnedOfflineAsset(id: "asset", category: .podcast, relativePath: "file", byteCount: 6, isReproducible: true)
        )
        let inventoryBytes = try await fixture.ledger.inventoryBytes()
        XCTAssertEqual(inventoryBytes, 6)
        XCTAssertTrue(try fixture.repository.loadOfflineStorageReservations().isEmpty, "no reservation is left behind")
    }

    func testCommitRejectsOutputLargerThanReservationWhenTheBudgetIsFull() async throws {
        let fixture = try makeFixture(limit: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.ledger.reserve(ownerId: "other", byteCount: 6)
        let reservation = try await fixture.ledger.reserve(ownerId: "writer", byteCount: 4)
        do {
            try await fixture.ledger.commit(
                reservationId: reservation.id,
                asset: OwnedOfflineAsset(id: "asset", category: .podcast, relativePath: "file", byteCount: 5, isReproducible: true)
            )
            XCTFail("Expected reservation overrun")
        } catch let error as OfflineStorageLedgerError {
            XCTAssertEqual(error, .reservationExceeded(reservedBytes: 4, actualBytes: 5))
        }
    }

    func testAdoptionIsIdempotentAndLedgerMatchesTrackedFiles() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let podcast = fixture.root.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: podcast, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: podcast.appending(path: "episode.m4a"))

        try await fixture.ledger.adoptExistingAssets()
        try await fixture.ledger.adoptExistingAssets()

        let inventoryBytes = try await fixture.ledger.inventoryBytes()
        let trackedBytes = try await fixture.ledger.trackedFilesystemBytes()
        XCTAssertEqual(inventoryBytes, 4)
        XCTAssertEqual(trackedBytes, 4)
    }

    func testAdoptionToleratesHistoricalDuplicatePaths() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relativePath = "GuidedOnboarding/guided-onboarding-1.m4a"
        let audio = fixture.root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4]).write(to: audio)
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "guided-legacy",
            category: .guidedTour,
            relativePath: relativePath,
            byteCount: 4,
            isReproducible: true
        ))
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "guided-current",
            category: .guidedTour,
            relativePath: relativePath,
            byteCount: 4,
            isReproducible: true
        ))

        try await fixture.ledger.adoptExistingAssets()

        XCTAssertEqual(try fixture.repository.loadOwnedOfflineAssets().count, 2)
    }

    func testBudgetUsesDecimalGigabytesMatchingSettingsLabel() {
        XCTAssertEqual(OfflineStorageBudget.bytesPerGigabyte, 1_000_000_000)
        XCTAssertEqual(OfflineStorageBudget().limitBytes, 5_000_000_000)
    }

    func testLoweredBudgetImmediatelyEvictsReproducibleAssets() async throws {
        let fixture = try makeFixture(limit: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.root.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: audio.appending(path: "episode.m4a"))
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "episode",
            category: .podcast,
            relativePath: "PodcastAudio/episode.m4a",
            byteCount: 7,
            isReproducible: true
        ))

        let residual = try await fixture.ledger.enforceBudget()
        let inventory = try await fixture.ledger.inventoryBytes()

        XCTAssertEqual(residual, 0)
        XCTAssertEqual(inventory, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.appending(path: "episode.m4a").path), "the evicted file is deleted, not only its row")
        XCTAssertTrue(try fixture.repository.loadOwnedOfflineAssets().isEmpty, "the evicted row is gone")
    }

    // #237: eviction deleted an article's rendered narration while the article still pointed at it,
    // and resuming the article then failed twice and stayed failed.
    func testEvictingRenderedNarrationDetachesTheArticleFirst() async throws {
        let fixture = try makeFixture(limit: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try writeAsset(fixture, relativePath: "PreparedSupertonicAudio/item-article-abc.m4a", category: .preparedAudio)
        let other = Item(id: "item-other", title: "Other", mediaType: "text", text: "Other.", externalReference: nil, status: "ready")
        try fixture.repository.saveItem(narratedArticle(file))
        try fixture.repository.saveItem(other)
        try fixture.repository.savePreparedAudioManifest(PreparedAudioManifest(
            id: "prepared-item-article", itemId: "item-article", sourcePackageId: "source",
            signature: TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                                          synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"),
            state: .readyOffline, plannedChunkCount: 1
        ))

        let residual = try await fixture.ledger.enforceBudget()

        XCTAssertEqual(residual, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try fixture.repository.loadItem(id: "item-article").media, "no item points at the deleted file")
        XCTAssertEqual(try fixture.repository.loadPreparedAudioManifests(itemId: "item-article").first?.state,
                       .needsRepreparation, "Prepare renders it again (#278)")
        XCTAssertEqual(try fixture.repository.loadItem(id: "item-other"), other)
    }

    func testClearingReproducibleAudioDetachesTheArticleFirst() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try writeAsset(fixture, relativePath: "PreparedSupertonicAudio/item-article-abc.m4a", category: .preparedAudio)
        try fixture.repository.saveItem(narratedArticle(file))

        _ = try await fixture.ledger.clearReproducibleAssets(in: [.preparedAudio])

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try fixture.repository.loadItem(id: "item-article").media)
    }

    func testEvictionKeepsAFileAnItemPlaysAsItsOnlyAudio() async throws {
        let fixture = try makeFixture(limit: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try writeAsset(fixture, relativePath: "PodcastAudio/episode.m4a", category: .podcast)
        let episode = Item(
            id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: file.absoluteString)
        )
        try fixture.repository.saveItem(episode)

        let residual = try await fixture.ledger.enforceBudget()

        XCTAssertEqual(residual, 2, "the budget stays over rather than breaking the episode")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try fixture.repository.loadItem(id: "item-episode"), episode)
    }

    // Audit of #242: eviction saved item copies from a snapshot taken before it began deleting,
    // so an edit saved in between (marking the item complete) was overwritten.
    func testEvictionKeepsAnItemEditSavedAfterItsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = ItemEditedAfterSnapshotRepository(editedItemId: "item-article", completedAt: completedAt)
        try repository.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 5))
        let fixture = Fixture(root: root, repository: repository, ledger: OfflineStorageLedger(repository: repository, rootDirectory: root))
        let file = try writeAsset(fixture, relativePath: "PreparedSupertonicAudio/item-article-abc.m4a", category: .preparedAudio)
        try repository.saveItem(narratedArticle(file))

        _ = try await fixture.ledger.enforceBudget()

        let saved = try repository.loadItem(id: "item-article")
        XCTAssertNil(saved.media)
        XCTAssertEqual(saved.sourceCompletedAt, completedAt, "the edit saved after the snapshot survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: #259: the ledger charged about 1.15 GB of files that no longer existed.

    func testStartupDropsRowsForMissingFilesAndTakesSizesFromDisk() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gone = directory.appending(path: "gone.m4a")
        let shorter = directory.appending(path: "shorter.m4a")
        try Data(repeating: 1, count: 6).write(to: gone)
        try Data(repeating: 1, count: 6).write(to: shorter)
        try await fixture.ledger.adoptExistingAssets()
        // Something deletes and rewrites files without telling the ledger.
        try FileManager.default.removeItem(at: gone)
        try Data(repeating: 1, count: 2).write(to: shorter)

        // The startup sequence: adopt, then enforce.
        try await fixture.ledger.adoptExistingAssets()
        _ = try await fixture.ledger.enforceBudget()

        let assets = try fixture.repository.loadOwnedOfflineAssets()
        XCTAssertEqual(assets.map(\.relativePath), ["PreparedSupertonicAudio/shorter.m4a"])
        XCTAssertEqual(assets.first?.byteCount, 2)
        let inventory = try await fixture.ledger.inventoryBytes()
        let tracked = try await fixture.ledger.trackedFilesystemBytes()
        XCTAssertEqual(inventory, tracked)
        let summary = await fixture.ledger.lastReconciliation?.summary
        XCTAssertEqual(summary, "missing=1 resized=1 merged=0 selfManaged=0 bytes=10")
    }

    func testOneFileIsChargedOnceWhenAdoptedAndThenCommittedByItsWriter() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relativePath = "PreparedAudio/item/chunks/0.wav"
        let file = fixture.root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: file)
        try await fixture.ledger.adoptExistingAssets()
        let reservation = try await fixture.ledger.reserve(ownerId: "writer", byteCount: 4)
        try await fixture.ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
            id: "prepared-item-chunk-0", itemId: "item", category: .preparedChunk,
            relativePath: relativePath, byteCount: 4, isReproducible: true
        ))
        XCTAssertEqual(try fixture.repository.loadOwnedOfflineAssets().count, 2, "today: two rows, charged twice")

        _ = try await fixture.ledger.enforceBudget()

        let assets = try fixture.repository.loadOwnedOfflineAssets()
        XCTAssertEqual(assets.map(\.id), ["prepared-item-chunk-0"], "the writer's row is kept")
        let inventory = try await fixture.ledger.inventoryBytes()
        XCTAssertEqual(inventory, 4)
    }

    func testAPhantomChunkDoesNotEvictRealNarration() async throws {
        let fixture = try makeFixture(limit: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "phantom-chunk", category: .preparedChunk, relativePath: "PreparedAudio/gone/chunks/0.wav",
            byteCount: 6, isReproducible: true
        ))
        let narration = fixture.root.appending(path: "PreparedSupertonicAudio/real.m4a")
        try FileManager.default.createDirectory(at: narration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4).write(to: narration)
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "real-narration", category: .preparedAudio, relativePath: "PreparedSupertonicAudio/real.m4a",
            byteCount: 4, isReproducible: true
        ))

        _ = try await fixture.ledger.reserve(ownerId: "download", byteCount: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: narration.path), "real narration survives")
        XCTAssertEqual(try fixture.repository.loadOwnedOfflineAssets().map(\.id), ["real-narration"])
    }

    // #645: an article's own reservation, to assemble its chunks or render the next one, evicted
    // the chunks it was about to read. A file a held reservation pins is skipped by every eviction
    // until that reservation is committed or released; if nothing else frees the room, the
    // reservation is refused and the file stays.
    func testAPinnedFileIsNotEvictedUntilItsReservationEnds() async throws {
        let fixture = try makeFixture(limit: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chunk = fixture.root.appending(path: "PreparedAudio/item/sig/chunks/00000.wav")
        try FileManager.default.createDirectory(at: chunk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 6).write(to: chunk)
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "chunk-0", category: .preparedChunk, relativePath: "PreparedAudio/item/sig/chunks/00000.wav",
            byteCount: 6, isReproducible: true
        ))

        do {
            _ = try await fixture.ledger.reserve(ownerId: "assembly", byteCount: 6, pinning: ["PreparedAudio/item/sig/chunks/00000.wav"])
            XCTFail("the only room is the pinned chunk itself")
        } catch let error as OfflineStorageLedgerError {
            XCTAssertEqual(error, .insufficientSpace(requiredBytes: 6, availableBytes: 4))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path), "a refused reservation deletes nothing it pins")

        let held = try await fixture.ledger.reserve(ownerId: "assembly", byteCount: 4, pinning: ["PreparedAudio/item/sig/chunks/00000.wav"])
        do {
            _ = try await fixture.ledger.reserve(ownerId: "download", byteCount: 1)
            XCTFail("another writer can't evict a file a held reservation pins")
        } catch OfflineStorageLedgerError.insufficientSpace {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))

        try await fixture.ledger.release(reservationId: held.id)
        _ = try await fixture.ledger.reserve(ownerId: "download", byteCount: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path), "once released, the chunk is ordinary evictable audio")
    }

    func testAMissingProtectedRowDoesNotRefuseAReservation() async throws {
        let fixture = try makeFixture(limit: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "missing-protected", category: .fingerprintMap, relativePath: "EpisodeMaps/gone/fingerprints.bin",
            byteCount: 10, isReproducible: true, protections: [.activeEpisodeMapPreparation]
        ))

        let reservation = try await fixture.ledger.reserve(ownerId: "download", byteCount: 1)

        XCTAssertEqual(reservation.byteCount, 1, "today this throws insufficientSpace")
    }

    // #530, Codex P1 on 3ff22d0: the row was deleted before its file, so playback starting in
    // between installed no protection, got the file's URL, and then lost the file.
    func testAnEvictedRowIsNeverVisibleWhileItsFileStillExists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-unlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RowDeletionObservingRepository()
        try repository.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 7))
        let ledger = OfflineStorageLedger(repository: repository, rootDirectory: root)
        let file = try writeAsset(Fixture(root: root, repository: repository, ledger: ledger),
                                  relativePath: "PodcastAudio/episode.m4a", category: .podcast)
        repository.afterRowDeleted = { _ in
            // Playback starting now finds no row to protect, so it must find no file either.
            repository.fileExistedWhenRowWasDeleted = FileManager.default.fileExists(atPath: file.path)
        }

        _ = try await ledger.reserve(ownerId: "other-download", byteCount: 7)

        XCTAssertEqual(repository.fileExistedWhenRowWasDeleted, false,
                       "the file must be gone by the time its row's deletion is visible")
    }

    // #530, Codex P2 on 3ff22d0: a file that couldn't be removed lost its row anyway, so its bytes
    // stopped counting and the next download could go over the budget.
    func testAFileThatCannotBeRemovedStaysCharged() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-unremovable-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemorySessionRepository()
        try repository.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 7))
        let ledger = OfflineStorageLedger(repository: repository, rootDirectory: root, fileManager: UnremovableFileManager())
        let file = try writeAsset(Fixture(root: root, repository: repository, ledger: ledger),
                                  relativePath: "PodcastAudio/episode.m4a", category: .podcast)

        for attempt in 1...2 {
            do {
                _ = try await ledger.reserve(ownerId: "other-download-\(attempt)", byteCount: 7)
                XCTFail("Attempt \(attempt): nothing could be freed, so the reservation must be refused")
            } catch OfflineStorageLedgerError.insufficientSpace {}
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let inventory = try await ledger.inventoryBytes()
        XCTAssertEqual(inventory, 7, "the file that stayed on disk is still charged")
        XCTAssertTrue(try repository.loadOfflineStorageReservations().isEmpty)
    }

    func testRemovingAnItemsPreparedAudioLeavesEverythingElse() async throws {
        // #322: after a PDF moves to the new extraction its prepared audio no longer matches.
        let fixture = try makeFixture(limit: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assets = [
            OwnedOfflineAsset(id: "chunk-a", itemId: "paper", category: .preparedChunk, relativePath: "PreparedAudio/paper/0.wav", byteCount: 10, isReproducible: true),
            OwnedOfflineAsset(id: "artifact-a", itemId: "paper", category: .preparedAudio, relativePath: "PreparedAudio/paper/all.caf", byteCount: 20, isReproducible: true),
            OwnedOfflineAsset(id: "recording-a", itemId: "paper", category: .recording, relativePath: "Recordings/ij-001.m4a", byteCount: 5, isReproducible: false),
            OwnedOfflineAsset(id: "chunk-b", itemId: "other", category: .preparedChunk, relativePath: "PreparedAudio/other/0.wav", byteCount: 7, isReproducible: true),
        ]
        for asset in assets {
            let url = fixture.root.appending(path: asset.relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(asset.byteCount)).write(to: url)
            try fixture.repository.saveOwnedOfflineAsset(asset)
        }

        let removed = try await fixture.ledger.removePreparedAudio(itemId: "paper")

        XCTAssertEqual(removed, 30)
        XCTAssertEqual(Set(try fixture.repository.loadOwnedOfflineAssets().map(\.id)), ["recording-a", "chunk-b"])
        for asset in assets {
            let exists = FileManager.default.fileExists(atPath: fixture.root.appending(path: asset.relativePath).path)
            XCTAssertEqual(exists, ["recording-a", "chunk-b"].contains(asset.id), asset.id)
        }
    }

    func testRemovingAnItemsPreparedAudioKeepsAFileAnotherItemPlays() async throws {
        // #344 audit 2: the upgraded paper's ledger row named a file another item still
        // played, and removal deleted it without asking who used it.
        let fixture = try makeFixture(limit: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shared = try writeAsset(fixture, relativePath: "PreparedSupertonicAudio/shared.m4a", category: .preparedAudio)
        let own = try writeAsset(fixture, relativePath: "PreparedAudio/paper/0.wav", category: .preparedChunk)
        let rows = try fixture.repository.loadOwnedOfflineAssets()
        for var row in rows {
            row.itemId = "paper"
            try fixture.repository.saveOwnedOfflineAsset(row)
        }
        let article = narratedArticle(shared)
        try fixture.repository.saveItem(article)
        try fixture.repository.saveItem(Item(id: "paper", title: "Paper", mediaType: "pdf", text: "Upgraded text.", externalReference: nil, status: "ready"))

        _ = try await fixture.ledger.removePreparedAudio(itemId: "paper")

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path), "the article still plays it")
        XCTAssertEqual(try fixture.repository.loadItem(id: "item-article"), article, "and keeps its narration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path), "the paper's own chunk goes")
        XCTAssertEqual(try fixture.repository.loadOwnedOfflineAssets().map(\.relativePath), ["PreparedSupertonicAudio/shared.m4a"],
                       "the kept file stays in the ledger")
    }

    func testDiscardingAStaleAssembledFileKeepsItWhenAnItemPlaysIt() async throws {
        // #344 re-audit: narration assembled for an upgraded PDF's old text was deleted
        // without asking whether another item plays the same file.
        let fixture = try makeFixture(limit: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let played = fixture.root.appending(path: "PreparedSupertonicAudio/played.m4a")
        let stale = fixture.root.appending(path: "PreparedSupertonicAudio/stale.m4a")
        try FileManager.default.createDirectory(at: played.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 7).write(to: played)
        try Data(count: 7).write(to: stale)
        let article = narratedArticle(played)
        try fixture.repository.saveItem(article)

        let keptPlayed = try await fixture.ledger.discardUncommittedFile(played)
        let removedStale = try await fixture.ledger.discardUncommittedFile(stale)

        XCTAssertFalse(keptPlayed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: played.path), "the article still plays it")
        XCTAssertEqual(try fixture.repository.loadItem(id: "item-article"), article)
        XCTAssertTrue(removedStale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "nothing plays it")
    }

    // #313: Clear Audio empties the rendered-speech cache, which the ledger doesn't track. An open cache
    // clears itself under its own lock.
    func testClearAudioAsksAnOpenCacheToClearItselfAndAddsItsBytes() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let episode = try writeAsset(fixture, relativePath: "PodcastAudio/episode.m4a", category: .podcast)
        let directory = fixture.root.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let untouched = directory.appending(path: "a.wav")
        try Data(repeating: 1, count: 5).write(to: untouched)
        let cache = RecordingCacheClearer(bytesFreed: 40)

        let cleared = try await fixture.ledger.clearReproducibleAudio(renderedSpeechCache: cache)

        XCTAssertEqual(cleared, 7 + 40, "the episode's 7 bytes and what the cache reported")
        XCTAssertEqual(cache.removeAllCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: episode.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path), "the open cache owns its files; the ledger doesn't also sweep the directory")
    }

    // This launch hasn't opened the cache, so the ledger clears its directory itself.
    func testClearAudioWithoutAnOpenCacheClearsTheCacheDirectoryByItself() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try writeAsset(fixture, relativePath: "PodcastAudio/episode.m4a", category: .podcast)
        let directory = fixture.root.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: directory.appending(path: "a.wav"))
        try Data(repeating: 1, count: 6).write(to: directory.appending(path: "b.WAV"))
        try Data(repeating: 1, count: 9).write(to: directory.appending(path: "keep.txt"))

        let cleared = try await fixture.ledger.clearReproducibleAudio(renderedSpeechCache: nil)

        XCTAssertEqual(cleared, 7 + 5 + 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.txt"])
    }

    func testClearAudioWithNoCacheDirectoryAtAllJustClearsTheAssets() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try writeAsset(fixture, relativePath: "PodcastAudio/episode.m4a", category: .podcast)

        let cleared = try await fixture.ledger.clearReproducibleAudio(renderedSpeechCache: nil)

        XCTAssertEqual(cleared, 7)
    }

    func testTheCacheFilesHelperListsOnlyRegularWavFilesAndSkipsHiddenOnes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cache-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "folder.wav", directoryHint: .isDirectory), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 3).write(to: root.appending(path: "one.wav"))
        try Data(repeating: 1, count: 4).write(to: root.appending(path: "TWO.WAV"))
        try Data(repeating: 1, count: 5).write(to: root.appending(path: "three.m4a"))
        try Data(repeating: 1, count: 6).write(to: root.appending(path: ".hidden.wav"))

        let entries = RenderedSpeechCacheFiles.entries(in: root)

        XCTAssertEqual(Set(entries.map(\.url.lastPathComponent)), ["one.wav", "TWO.WAV"])
        XCTAssertEqual(entries.map(\.size).sorted(), [3, 4])
        XCTAssertEqual(RenderedSpeechCacheFiles.entries(in: root.appending(path: "missing")).count, 0)
    }

    private func writeAsset(_ fixture: Fixture, relativePath: String, category: OfflineAssetCategory) throws -> URL {
        let file = fixture.root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: file)
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: relativePath, category: category, relativePath: relativePath, byteCount: 7, isReproducible: true
        ))
        return file
    }

    private func narratedArticle(_ file: URL) -> Item {
        Item(
            id: "item-article", title: "Article", mediaType: "text", text: "Article text.", externalReference: nil,
            status: "ready",
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: file.absoluteString, durationMs: 1_000, nativeMediaId: file.absoluteString)
        )
    }

    private struct Fixture {
        let root: URL
        let repository: InMemorySessionRepository
        let ledger: OfflineStorageLedger
    }

    private func makeFixture(limit: Int64) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = InMemorySessionRepository()
        try repository.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: limit))
        return Fixture(
            root: root,
            repository: repository,
            ledger: OfflineStorageLedger(repository: repository, rootDirectory: root)
        )
    }
}

/// Saves an edit to one item right after eviction takes its snapshot of the items, as the app's
/// main actor can while the ledger actor is evicting.
private final class ItemEditedAfterSnapshotRepository: InMemorySessionRepository, @unchecked Sendable {
    private let editedItemId: String
    private let completedAt: Date

    init(editedItemId: String, completedAt: Date) {
        self.editedItemId = editedItemId
        self.completedAt = completedAt
        super.init()
    }

    override func listItems(includeDeleted: Bool = false) throws -> [Item] {
        let snapshot = try super.listItems(includeDeleted: includeDeleted)
        if var item = items[editedItemId] {
            item.sourceCompletedAt = completedAt
            items[editedItemId] = item
        }
        return snapshot
    }
}

/// Reports each conditional row deletion as soon as it commits, which is when the app's main actor
/// could next read the store.
private final class RowDeletionObservingRepository: InMemorySessionRepository, @unchecked Sendable {
    var afterRowDeleted: ((String) -> Void)?
    var fileExistedWhenRowWasDeleted: Bool?

    override func deleteOwnedOfflineAsset(id: String, if shouldDelete: (OwnedOfflineAsset) -> Bool) throws -> Bool {
        let deleted = try super.deleteOwnedOfflineAsset(id: id, if: shouldDelete)
        if deleted { afterRowDeleted?(id) }
        return deleted
    }
}

/// A file system that refuses every removal, as a locked or permission-denied file would.
private final class UnremovableFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Stands in for the rendered-speech cache the app has open.
private final class RecordingCacheClearer: RenderedSpeechCacheClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let bytesFreed: Int64

    init(bytesFreed: Int64) { self.bytesFreed = bytesFreed }

    var removeAllCalls: Int { lock.withLock { calls } }

    func removeAll() -> Int64 {
        lock.withLock { calls += 1 }
        return bytesFreed
    }
}
