import Foundation
@testable import SessionKit
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

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

    func testLocalSourceImporterCoordinatesFileSizeAndCopy() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appending(path: "provider-source.epub")
        let destination = fixture.root.appending(path: "provider-copy.epub")
        let contents = Data("provider-backed bytes".utf8)
        try contents.write(to: source)
        let importer = LocalSourceImporter(
            repository: fixture.repository,
            ledger: fixture.ledger,
            applicationSupportDirectory: fixture.root
        )

        let size = try await importer.fileSize(source)
        try await importer.copySecurityScoped(source, to: destination)

        XCTAssertEqual(size, Int64(contents.count))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
    }

    func testEPUBImporterRejectsNonFileURLBeforeLoading() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let importer = LocalSourceImporter(
            repository: fixture.repository,
            ledger: fixture.ledger,
            applicationSupportDirectory: fixture.root
        )

        do {
            _ = try await importer.importEPUB(from: XCTUnwrap(URL(string: "https://example.com/book.epub")))
            XCTFail("Expected non-file URL rejection")
        } catch let error as LocalSourceImportError {
            XCTAssertEqual(error, .unsupportedURL)
        }
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

    // #313: the rendered speech cache deletes files by its own LRU without telling the ledger, so
    // rows adopted for it named deleted files until the next reconciliation. It manages its own
    // size, so the ledger leaves it alone: rows an earlier build adopted are dropped at launch
    // (the files stay), adoption skips it, and an LRU pass leaves the ledger matching the disk.
    func testARenderedSpeechCacheLRUPassLeavesTheLedgerMatchingTheDisk() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let episode = try writeAsset(fixture, relativePath: "PodcastAudio/episode.m4a", category: .podcast)
        let rendered = fixture.root.appending(path: "rendered.wav")
        try Data(repeating: 2, count: 100).write(to: rendered)
        let result = SupertonicNarrationResult(
            audioURL: rendered, duration: 1, sampleRate: 44_100, renderDuration: 0, sessionLoadCount: 0
        )
        let cache = try RenderedSpeechDiskCache(
            directory: fixture.root.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory),
            limitBytes: 1_000
        )
        let first = try cache.store(result, text: "one", voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        _ = try cache.store(result, text: "two", voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        // Build 29 adopted a cache file at its last launch.
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "adopted-build-29", category: .preparedChunk,
            relativePath: "RenderedSpeechCache/\(first.audioURL.lastPathComponent)", byteCount: 100, isReproducible: true
        ))

        // The startup sequence: adopt, then enforce.
        try await fixture.ledger.adoptExistingAssets()
        _ = try await fixture.ledger.enforceBudget()
        let summary = await fixture.ledger.lastReconciliation?.summary
        XCTAssertEqual(summary, "missing=0 resized=0 merged=0 selfManaged=1 bytes=100", "Build 29's row is dropped")
        // An LRU pass: the cache now fits one file, so the next store evicts the other two.
        cache.setLimitBytes(100)
        let third = try cache.store(result, text: "three", voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.audioURL.path), "the LRU pass ran")

        let assets = try fixture.repository.loadOwnedOfflineAssets()
        let missing = assets.filter { !FileManager.default.fileExists(atPath: fixture.root.appending(path: $0.relativePath).path) }
        XCTAssertEqual(missing.map(\.relativePath), [], "no row names a missing file")
        let inventory = try await fixture.ledger.inventoryBytes()
        let tracked = try await fixture.ledger.trackedFilesystemBytes()
        XCTAssertEqual(inventory, tracked, "the ledger total matches the disk")
        XCTAssertEqual(assets.map(\.relativePath), ["PodcastAudio/episode.m4a"], "the ledger doesn't track the rendered cache")
        XCTAssertTrue(FileManager.default.fileExists(atPath: episode.path), "a real download is never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.audioURL.path), "the ledger leaves the cache's files alone")
    }

    // #313: Clear Audio still clears the rendered speech cache now that the ledger doesn't track it,
    // whether or not this launch has opened the cache.
    func testClearAudioAlsoClearsTheRenderedSpeechCache() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let episode = try writeAsset(fixture, relativePath: "PodcastAudio/episode.m4a", category: .podcast)
        let directory = fixture.root.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: directory.appending(path: "a.wav"))
        try Data(repeating: 1, count: 5).write(to: directory.appending(path: "b.wav"))

        let clearedUnopened = try await fixture.ledger.clearReproducibleAudio(renderedSpeechCache: nil)

        XCTAssertEqual(clearedUnopened, 17)
        XCTAssertFalse(FileManager.default.fileExists(atPath: episode.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        let rendered = fixture.root.appending(path: "rendered.wav")
        try Data(repeating: 2, count: 100).write(to: rendered)
        let cache = try RenderedSpeechDiskCache(directory: directory, limitBytes: 1_000)
        let stored = try cache.store(
            SupertonicNarrationResult(audioURL: rendered, duration: 1, sampleRate: 44_100, renderDuration: 0, sessionLoadCount: 0),
            text: "one", voice: .m2, language: "en", speed: 1, synthesisSteps: 8
        )

        let clearedOpen = try await fixture.ledger.clearReproducibleAudio(renderedSpeechCache: cache)

        XCTAssertEqual(clearedOpen, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.audioURL.path))
        XCTAssertEqual(cache.sizeBytes, 0)
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
