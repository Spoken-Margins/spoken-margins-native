import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

/// The ledger's tests that need the app: its model, importers, the download coordinator and the real
/// rendered-speech cache. The ledger's own tests are in SessionKitCoreTests/OfflineStorageLedgerTests (#318).
final class OfflineStorageLedgerAppTests: XCTestCase {
    @MainActor
    func testModelKeepsFallbackLedgerAndUsesItsStoreAndRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lazy-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        XCTAssertNil(model.offlineStorageLedger)

        let ledger = model.requireOfflineLedger(store: store, rootDirectory: root)
        XCTAssertTrue(model.offlineStorageLedger === ledger)
        XCTAssertTrue(model.requireOfflineLedger(store: store, rootDirectory: root) === ledger)
        let reservation = try await ledger.reserve(ownerId: "lazy-ledger", byteCount: 3)
        XCTAssertEqual(try store.loadOfflineStorageReservations().map(\.id), [reservation.id])
        let audio = root.appending(path: "PodcastAudio/episode.m4a")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audio)
        try await ledger.adoptExistingAssets()
        XCTAssertEqual(try store.loadOwnedOfflineAssets().map(\.relativePath), ["PodcastAudio/episode.m4a"])
    }

    @MainActor
    func testModelReusesConfiguredLedgerWithoutEvaluatingFallbackDirectory() throws {
        enum DirectoryError: Error { case unavailable }
        let store = try SQLiteSessionStore(path: ":memory:")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let configured = OfflineStorageLedger(repository: store, rootDirectory: FileManager.default.temporaryDirectory)
        model.offlineStorageLedger = configured
        func unavailableDirectory() throws -> URL { throw DirectoryError.unavailable }

        let reused = try model.requireOfflineLedger(store: store, rootDirectory: try unavailableDirectory())
        XCTAssertTrue(reused === configured)
        model.offlineStorageLedger = nil
        XCTAssertThrowsError(try model.requireOfflineLedger(store: store, rootDirectory: try unavailableDirectory()))
        XCTAssertNil(model.offlineStorageLedger)
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
            audioURL: rendered, duration: 1, sampleRate: 44_100, renderDuration: 0, sessionLoadCount: 0,
            engine: SupertonicNarrationResult.supertonicEngine
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
            SupertonicNarrationResult(audioURL: rendered, duration: 1, sampleRate: 44_100, renderDuration: 0, sessionLoadCount: 0, engine: SupertonicNarrationResult.supertonicEngine),
            text: "one", voice: .m2, language: "en", speed: 1, synthesisSteps: 8
        )

        let clearedOpen = try await fixture.ledger.clearReproducibleAudio(renderedSpeechCache: cache)

        XCTAssertEqual(clearedOpen, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.audioURL.path))
        XCTAssertEqual(cache.sizeBytes, 0)
    }

    // #1291 APO-04: Settings > Offline Storage > Clear Audio promises that "imported audiobooks,
    // recordings, Margins, and protected active playback will remain". The UI test that checked the
    // alert never ran (its seed had nothing to clear, and Gate1FlowUITests runs nowhere), so this
    // drives the model's real Clear Audio action over files laid out and enrolled the way the app does.
    @MainActor
    func testClearAudioKeepsMarginsAudiobooksAndTheEpisodeThatIsPlaying() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        func write(_ relativePath: String) throws -> URL {
            let file = fixture.root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 7).write(to: file)
            return file
        }
        let episode = try write("PodcastAudio/episode.m4a")
        let playing = try write("PodcastAudio/playing.m4a")
        let margin = try write("Interjections/margin-1.m4a")
        let audiobook = try write("Audiobooks/book.m4b")
        try await fixture.ledger.adoptExistingAssets()
        let playingId = try XCTUnwrap(try fixture.repository.loadOwnedOfflineAssets()
            .first { $0.relativePath == "PodcastAudio/playing.m4a" }?.id)
        try await fixture.ledger.protect(assetId: playingId, reason: .activePlayback, enabled: true)
        let before = try await fixture.ledger.presentationSnapshot()
        XCTAssertEqual(before.clearableBytes, 7, "Clear is enabled, and offers only the episode nobody is playing")

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.offlineStorageLedger = fixture.ledger
        model.clearReproducibleOfflineAudio()
        let deadline = Date().addingTimeInterval(10)
        while !model.statusMessage.hasPrefix("Cleared "), model.lastError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.statusMessage.hasPrefix("Cleared "), model.statusMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: episode.path), "the reproducible episode is cleared")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playing.path), "the episode that is playing stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: margin.path), "a recorded Margin stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audiobook.path), "an imported audiobook stays")
        XCTAssertEqual(
            Set(try fixture.repository.loadOwnedOfflineAssets().map(\.relativePath)),
            ["PodcastAudio/playing.m4a", "Interjections/margin-1.m4a", "Audiobooks/book.m4b"]
        )
    }

    // #287: playback can start while the ledger checks files. Reconcile used to write back the
    // row it had read before that, so the playing episode lost its protection and could be evicted.
    @MainActor
    func testAPlayingEpisodeKeepsItsProtectionWhenReconcileRunsAtTheSameMoment() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        let podcasts = support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: podcasts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 3).write(to: podcasts.appending(path: "episode.mp3"))
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-episode", itemId: "episode", remoteURL: "https://example.com/episode.mp3",
            localRelativePath: "episode.mp3", state: .availableOffline, bytesWritten: 3
        ))
        // A stale size puts the row in reconcile's write-back.
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "asset-episode", itemId: "episode", category: .podcast, relativePath: "PodcastAudio/episode.mp3",
            byteCount: 10, isReproducible: true
        ))
        let fileManager = FileCheckHookFileManager()
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: support, fileManager: fileManager)
        let coordinator = try PodcastDownloadCoordinator(
            store: store, ledger: ledger, applicationSupportDirectory: support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false
        )
        fileManager.onFirstCheck = {
            // The ledger runs off the main actor, which is free while this test awaits it.
            DispatchQueue.main.sync { MainActor.assumeIsolated { coordinator.configureActiveItem("episode") } }
        }

        try await ledger.reconcileWithDisk()

        XCTAssertTrue(fileManager.didFire, "playback started during the file check")
        let row = try XCTUnwrap(store.loadOwnedOfflineAssets().first { $0.id == "asset-episode" })
        XCTAssertEqual(row.byteCount, 3, "the size still comes from disk")
        XCTAssertEqual(row.protections, [.activePlayback], "the playing episode keeps its protection")
    }

    // #530: eviction decided from rows read before it deleted anything, so an episode that started
    // playing after that read was deleted mid-play.
    @MainActor
    func testAnEpisodeThatStartsPlayingDuringEvictionIsNotDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-evict-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        let podcasts = support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: podcasts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = podcasts.appending(path: "episode.mp3")
        try Data(repeating: 1, count: 3).write(to: file)
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        try store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 3))
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-episode", itemId: "episode", remoteURL: "https://example.com/episode.mp3",
            localRelativePath: "episode.mp3", state: .availableOffline, bytesWritten: 3
        ))
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "podcast-offline-episode", itemId: "episode", category: .podcast,
            relativePath: "PodcastAudio/episode.mp3", byteCount: 3, isReproducible: true
        ))
        let fileManager = EvictionHookFileManager()
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: support, fileManager: fileManager)
        let coordinator = try PodcastDownloadCoordinator(
            store: store, ledger: ledger, applicationSupportDirectory: support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false
        )
        fileManager.beforeDelete = {
            // The plan has chosen the idle episode. The ledger runs off the main actor, which is
            // free while this test awaits it, so playback can start now.
            DispatchQueue.main.sync { MainActor.assumeIsolated { coordinator.configureActiveItem("episode") } }
        }

        do {
            _ = try await ledger.reserve(ownerId: "other-download", byteCount: 3)
            XCTFail("Nothing could be freed, so the reservation must be refused")
        } catch OfflineStorageLedgerError.insufficientSpace {}

        XCTAssertTrue(fileManager.didFire, "playback started after the eviction plan was made")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the playing episode's file survives")
        let row = try XCTUnwrap(store.loadOwnedOfflineAssets().first { $0.id == "podcast-offline-episode" })
        XCTAssertEqual(row.protections, [.activePlayback])
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "episode"))
        XCTAssertTrue(try store.loadOfflineStorageReservations().isEmpty)
        coordinator.shutdown()
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

/// Runs a hook the first time the ledger checks the episode's file, inside `reconcileWithDisk`.
private final class FileCheckHookFileManager: FileManager, @unchecked Sendable {
    var onFirstCheck: (@Sendable () -> Void)?
    private(set) var didFire = false

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if !didFire, path.hasSuffix("episode.mp3"), let hook = onFirstCheck {
            didFire = true
            hook()
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
}

/// Runs a hook the first time eviction checks the episode's file, after the plan is made and
/// before anything is deleted. Reconcile's directory-aware checks don't fire it.
private final class EvictionHookFileManager: FileManager, @unchecked Sendable {
    var beforeDelete: (@Sendable () -> Void)?
    private(set) var didFire = false
    private var checkingWithDirectory = false

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        checkingWithDirectory = true
        defer { checkingWithDirectory = false }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    override func fileExists(atPath path: String) -> Bool {
        if !checkingWithDirectory, !didFire, path.hasSuffix("episode.mp3"), let hook = beforeDelete {
            didFire = true
            hook()
        }
        return super.fileExists(atPath: path)
    }
}
