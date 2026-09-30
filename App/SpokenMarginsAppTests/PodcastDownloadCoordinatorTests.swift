import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class PodcastDownloadCoordinatorTests: XCTestCase {
    func testRegistrationPersistsSecureDownloadTransportForExistingHTTPEnclosure() throws {
        let fixture = try makeFixture()
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )
        coordinator.setNetworkTransportForTesting(.cellular)
        let url = try XCTUnwrap(URL(string:
            "http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download-rss/proto/http/vpid/p0kbxb7s.mp3"
        ))

        coordinator.register(itemId: "bbc-episode", remoteURL: url)

        let expected = "https://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download-rss/proto/https/vpid/p0kbxb7s.mp3"
        XCTAssertEqual(coordinator.recordsByItemId["bbc-episode"]?.remoteURL, expected)
        XCTAssertEqual(
            try fixture.store.loadAudioAssets(itemId: "bbc-episode").first { $0.availability == .remote }?.url,
            expected
        )

        let generic = try XCTUnwrap(URL(string: "http://media.example.com:80/show/episode.mp3?token=abc#clip"))
        coordinator.register(itemId: "generic-episode", remoteURL: generic)
        XCTAssertEqual(
            coordinator.recordsByItemId["generic-episode"]?.remoteURL,
            "https://media.example.com/show/episode.mp3?token=abc#clip"
        )

        let secure = try XCTUnwrap(URL(string: "https://example.com/episode.mp3"))
        coordinator.register(itemId: "secure-episode", remoteURL: secure)
        XCTAssertEqual(coordinator.recordsByItemId["secure-episode"]?.remoteURL, secure.absoluteString)

        let file = try XCTUnwrap(URL(string: "file:///tmp/episode.mp3"))
        coordinator.register(itemId: "file-episode", remoteURL: file)
        XCTAssertEqual(coordinator.recordsByItemId["file-episode"]?.state, .failed)
        XCTAssertEqual(
            coordinator.recordsByItemId["file-episode"]?.failureReason,
            "The podcast audio URL does not support a secure HTTP connection."
        )
    }

    func testRetryMigratesPreviouslyFailedBBCDownloadWithoutReimport() throws {
        let fixture = try makeFixture()
        let original = "http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download-rss/proto/http/vpid/p0kbxb7s.mp3"
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-bbc-episode",
            itemId: "bbc-episode",
            remoteURL: original,
            state: .failed,
            failureReason: "The resource could not be loaded because the App Transport Security policy requires the use of a secure connection."
        ))
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )

        coordinator.setNetworkTransportForTesting(.unavailable)
        coordinator.retry(itemId: "bbc-episode")

        XCTAssertEqual(
            coordinator.recordsByItemId["bbc-episode"]?.remoteURL,
            "https://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download-rss/proto/https/vpid/p0kbxb7s.mp3"
        )
        XCTAssertEqual(coordinator.recordsByItemId["bbc-episode"]?.retryCount, 1)
        XCTAssertEqual(coordinator.recordsByItemId["bbc-episode"]?.state, .waitingForWiFi)
        XCTAssertNil(coordinator.recordsByItemId["bbc-episode"]?.failureReason)
    }

    func testCellularRegistrationStreamsWithoutAutomaticDownloadAndDeduplicatesRecord() throws {
        let fixture = try makeFixture()
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )
        coordinator.setNetworkTransportForTesting(.cellular)
        let url = try XCTUnwrap(URL(string: "https://example.com/episode.mp3"))

        coordinator.register(itemId: "episode", remoteURL: url)
        coordinator.register(itemId: "episode", remoteURL: url)

        XCTAssertEqual(coordinator.recordsByItemId["episode"]?.state, .streamingOnly)
        XCTAssertEqual(try fixture.store.loadPodcastDownloads().count, 1)
        XCTAssertEqual(try fixture.store.loadAudioAssets(itemId: "episode").filter { $0.availability == .remote }.count, 1)
    }

    func testManualDownloadDoesNotClaimToStartWithoutAConnection() throws {
        let fixture = try makeFixture()
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )
        coordinator.setNetworkTransportForTesting(.unavailable)
        let url = try XCTUnwrap(URL(string: "https://example.com/episode.mp3"))
        coordinator.register(itemId: "episode", remoteURL: url)

        XCTAssertFalse(coordinator.downloadNow(itemId: "episode"))
        XCTAssertEqual(coordinator.recordsByItemId["episode"]?.state, .waitingForWiFi)
    }

    func testClearDownloadsProtectsActivePlaybackAndEvictsOtherLocalFile() throws {
        let fixture = try makeFixture()
        let audioDirectory = fixture.support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        for itemId in ["active", "old"] {
            let file = audioDirectory.appending(path: "\(itemId).mp3")
            try Data([1, 2, 3]).write(to: file)
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(
                id: "download-\(itemId)",
                itemId: itemId,
                remoteURL: "https://example.com/\(itemId).mp3",
                localRelativePath: file.lastPathComponent,
                state: .availableOffline,
                bytesWritten: 3,
                expectedBytes: 3
            ))
            try fixture.store.saveAudioAsset(AudioAsset(
                id: "podcast-local-\(itemId)",
                itemId: itemId,
                audioSourceType: .nativeMediaFile,
                availability: .localPhone,
                filePath: file.lastPathComponent
            ))
        }
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )
        coordinator.configureActiveItem("active")

        coordinator.clearDownloads()

        XCTAssertEqual(coordinator.recordsByItemId["active"]?.state, .availableOffline)
        XCTAssertEqual(coordinator.recordsByItemId["old"]?.state, .evicted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDirectory.appending(path: "active.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.appending(path: "old.mp3").path))
        XCTAssertTrue(try fixture.store.loadAudioAssets(itemId: "old").isEmpty)
    }

    func testPermanentItemRemovalDeletesLocalRemoteAndDownloadRecords() throws {
        let fixture = try makeFixture()
        let audioDirectory = fixture.support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let file = audioDirectory.appending(path: "episode.mp3")
        try Data([1]).write(to: file)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-episode",
            itemId: "episode",
            remoteURL: "https://example.com/episode.mp3",
            localRelativePath: file.lastPathComponent,
            state: .availableOffline,
            bytesWritten: 1
        ))
        try fixture.store.saveAudioAsset(AudioAsset(id: "podcast-local-episode", itemId: "episode", audioSourceType: .nativeMediaFile, availability: .localPhone, filePath: file.lastPathComponent))
        try fixture.store.saveAudioAsset(AudioAsset(id: "podcast-remote-episode", itemId: "episode", audioSourceType: .remoteStream, availability: .remote, url: "https://example.com/episode.mp3"))
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )

        try fixture.store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "podcast-offline-episode", itemId: "episode", category: .podcast,
            relativePath: "PodcastAudio/episode.mp3", byteCount: 1, isReproducible: true
        ))
        coordinator.removeItem("episode")

        XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty)
        XCTAssertNil(try fixture.store.loadPodcastDownload(itemId: "episode"))
        XCTAssertTrue(try fixture.store.loadAudioAssets(itemId: "episode").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testValidatedLocalURLRequiresAvailableNonemptyFile() throws {
        let fixture = try makeFixture()
        let audioDirectory = fixture.support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let validFile = audioDirectory.appending(path: "valid.mp3")
        let emptyFile = audioDirectory.appending(path: "empty.mp3")
        try Data([1, 2, 3]).write(to: validFile)
        try Data().write(to: emptyFile)
        for (itemId, file) in [("valid", validFile), ("empty", emptyFile)] {
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(
                id: "download-\(itemId)",
                itemId: itemId,
                remoteURL: "https://example.com/\(itemId).mp3",
                localRelativePath: file.lastPathComponent,
                state: .availableOffline,
                bytesWritten: Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            ))
        }
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store,
            applicationSupportDirectory: fixture.support,
            cacheLimit: .five,
            monitorsNetwork: false,
            usesBackgroundSession: false
        )

        XCTAssertEqual(coordinator.validatedLocalURL(for: "valid"), validFile)
        XCTAssertNil(coordinator.validatedLocalURL(for: "empty"))
        XCTAssertNil(coordinator.validatedLocalURL(for: "missing"))
        try FileManager.default.removeItem(at: validFile)
        XCTAssertNil(coordinator.validatedLocalURL(for: "valid"))
        XCTAssertEqual(coordinator.recordsByItemId["valid"]?.state, .failed)
        XCTAssertNil(coordinator.recordsByItemId["valid"]?.localRelativePath)
        XCTAssertEqual(try fixture.store.loadPodcastDownloads().first { $0.itemId == "valid" }?.state, .failed)
    }

    func testFailedReplacementRetainsPreviouslyDownloadedEpisodeAcrossRelaunch() async throws {
        let fixture = try makeFixture()
        let directory = fixture.support.appending(path: "PodcastAudio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = directory.appending(path: "saved.mp3")
        try Data([1, 2, 3, 4]).write(to: saved)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-episode", itemId: "episode", remoteURL: "https://example.com/audio",
            localRelativePath: saved.lastPathComponent, state: .availableOffline,
            bytesWritten: 4, expectedBytes: 4
        ))
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false,
            contentLength: { _, _ in throw URLError(.timedOut) }
        )

        coordinator.redownload(itemId: "episode")
        XCTAssertEqual(coordinator.validatedLocalURL(for: "episode"), saved)
        await coordinator.preparationTasks["episode"]?.value
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        XCTAssertEqual(coordinator.validatedLocalURL(for: "episode"), saved)
        XCTAssertEqual(try Data(contentsOf: saved), Data([1, 2, 3, 4]))
        XCTAssertNotNil(coordinator.recordsByItemId["episode"]?.failureReason)
        coordinator.shutdown()

        let restored = try PodcastDownloadCoordinator(
            store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false
        )
        XCTAssertEqual(restored.validatedLocalURL(for: "episode"), saved)
        restored.shutdown()
    }

    func testFirstDownloadInProgressIsNotMarkedFailedWhenQueried() async throws {
        let fixture = try makeFixture()
        let head = DownloadHeadGate()
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false,
            contentLength: { _, _ in await head.length() }, startDownload: { _, _ in })
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://example.com/audio")!, userInitiated: true)
        await head.waitUntilRequested()

        XCTAssertNil(coordinator.validatedLocalURL(for: "episode"))
        XCTAssertEqual(coordinator.status(itemId: "episode"), .downloading)
        XCTAssertEqual(try fixture.store.loadPodcastDownload(itemId: "episode")?.state, .downloading)

        let preparation = try XCTUnwrap(coordinator.preparationTasks["episode"])
        await head.finish(8)
        await preparation.value
        coordinator.shutdown()
    }

    func testLegacyFailedReplacementWithSavedFileRecoversOnLaunch() throws {
        let fixture = try makeFixture()
        let directory = fixture.support.appending(path: "PodcastAudio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = directory.appending(path: "saved.mp3")
        try Data([1, 2, 3]).write(to: saved)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-episode", itemId: "episode", remoteURL: "https://example.com/audio",
            localRelativePath: saved.lastPathComponent, state: .failed,
            bytesWritten: 0, expectedBytes: 100,
            failureReason: "unknown error"
        ))

        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false
        )
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        XCTAssertEqual(coordinator.validatedLocalURL(for: "episode"), saved)
        XCTAssertEqual(try fixture.store.loadPodcastDownload(itemId: "episode")?.bytesWritten, 3)
        coordinator.shutdown()
    }

    func testSharedStorageReservationCannotEvictActivePodcastIncludingAdoptedFiles() async throws {
        let fixture = try makeFixture()
        let directory = fixture.support.appending(path: "PodcastAudio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 6))
        for id in ["active", "old"] {
            try Data([1, 2, 3]).write(to: directory.appending(path: "\(id).mp3"))
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(
                id: "download-\(id)", itemId: id, remoteURL: "https://example.com/\(id).mp3",
                localRelativePath: "\(id).mp3", state: .availableOffline, bytesWritten: 3
            ))
            // Inventory-adopted files have no item ID.
            try fixture.store.saveOwnedOfflineAsset(OwnedOfflineAsset(
                id: "asset-\(id)", category: .podcast, relativePath: "PodcastAudio/\(id).mp3",
                byteCount: 3, isReproducible: true
            ))
        }
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store, ledger: ledger, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false
        )
        coordinator.configureActiveItem("active")
        let reservation = try await ledger.reserve(ownerId: "margin-work", byteCount: 3)
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "active"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "old.mp3").path))
        do {
            _ = try await ledger.reserve(ownerId: "more-work", byteCount: 1)
            XCTFail("Must refuse storage rather than delete the active episode")
        } catch is OfflineStorageLedgerError {}
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "active"))
        try await ledger.release(reservationId: reservation.id)
        coordinator.configureActiveItem(nil)
        _ = try await ledger.reserve(ownerId: "after-listening", byteCount: 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "active.mp3").path))
    }

    func testDeletionWhileHeadIsSuspendedCannotRecreateDownload() async throws {
        let fixture = try makeFixture()
        let head = DownloadHeadGate()
        var starts = 0
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false,
            contentLength: { _, _ in await head.length() }, startDownload: { _, _ in starts += 1 })
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://example.com/audio")!)
        await head.waitUntilRequested()
        let preparation = try XCTUnwrap(coordinator.preparationTasks["episode"])
        coordinator.removeItem("episode")
        await head.finish(8)
        await preparation.value
        XCTAssertEqual(starts, 0)
        XCTAssertNil(try fixture.store.loadPodcastDownload(itemId: "episode"))
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
        coordinator.shutdown()
    }

    func testLeavingWiFiWhileHeadIsSuspendedCancelsOnlyAutomaticPreparation() async throws {
        let fixture = try makeFixture()
        let head = DownloadHeadGate()
        var starts = 0
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false,
            contentLength: { _, _ in await head.length() }, startDownload: { _, _ in starts += 1 })
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://example.com/audio")!)
        await head.waitUntilRequested()
        let preparation = try XCTUnwrap(coordinator.preparationTasks["episode"])
        coordinator.setNetworkTransportForTesting(.cellular)
        await head.finish(8)
        await preparation.value
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(try fixture.store.loadPodcastDownload(itemId: "episode")?.state, .streamingOnly)
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
        coordinator.shutdown()
    }

    func testRestoredTaskAdoptsPersistedReservationAndPublishesOnlyAfterCommit() async throws {
        let fixture = try makeFixture()
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
        let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:restored", byteCount: 8)
        let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "restored",
                                             reservationId: reservation.id, userInitiated: true)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
            remoteURL: "https://example.com/audio", state: .downloading))
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
        XCTAssertEqual(PodcastDownloadAttempt.decode(attempt.taskDescription), attempt)
        XCTAssertTrue(coordinator.restoreAttempt(attempt))
        let staged = fixture.root.appending(path: "restored.mp3")
        try Data([1, 2, 3]).write(to: staged)
        var published = false
        coordinator.onLocalAssetReady = { id, url in
            published = true
            XCTAssertEqual(id, "episode")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try? fixture.store.loadOwnedOfflineAssets().first?.byteCount, 3)
            XCTAssertEqual(try? fixture.store.loadOfflineStorageReservations().count, 0)
        }
        coordinator.completeDownload(attempt, error: nil)
        await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: true)
        XCTAssertTrue(published)
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "episode"))
        coordinator.shutdown()
    }

    func testLateAttemptCannotOverwriteOrFailReplacementDownload() async throws {
        let fixture = try makeFixture()
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
        var started: [PodcastDownloadAttempt] = []
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false,
            contentLength: { _, _ in 8 }, startDownload: { _, description in
                started.append(PodcastDownloadAttempt.decode(description)!)
            })
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://example.com/audio")!)
        try await waitForStarts(1, starts: { started.count })
        let old = started[0]
        coordinator.removeItem("episode")
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://example.com/new-audio")!)
        try await waitForStarts(2, starts: { started.count })
        let current = started[1]
        let newFile = fixture.root.appending(path: "new.mp3")
        try Data([4, 5, 6]).write(to: newFile)
        await coordinator.finishDownload(current, stagedURL: newFile, responseOK: true)
        let local = try XCTUnwrap(coordinator.validatedLocalURL(for: "episode"))
        let oldFile = fixture.root.appending(path: "old.mp3")
        try Data([9]).write(to: oldFile)
        coordinator.completeDownload(old, error: URLError(.networkConnectionLost))
        await coordinator.finishDownload(old, stagedURL: oldFile, responseOK: true)
        XCTAssertEqual(try Data(contentsOf: local), Data([4, 5, 6]))
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
        XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().count, 1)
        coordinator.shutdown()
    }

    func testHTTPAndOversizedFileFailuresReleaseReservationWithoutAvailability() async throws {
        for httpOK in [false, true] {
            let fixture = try makeFixture()
            // The oversized case must not fit the budget either; an overrun that fits is accepted (see below).
            try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 2))
            let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
            let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:failure", byteCount: 1)
            let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "failure",
                reservationId: reservation.id, userInitiated: true)
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
                remoteURL: "https://example.com/audio", state: .downloading))
            let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
                applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
            let staged = fixture.root.appending(path: "failure.mp3")
            try Data([1, 2, 3]).write(to: staged)
            await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: httpOK)
            XCTAssertEqual(coordinator.status(itemId: "episode"), .failed)
            XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
            XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty)
            XCTAssertNil(coordinator.validatedLocalURL(for: "episode"))
            coordinator.shutdown()
        }
    }

    func testAdInsertedDownloadLargerThanItsHeadLengthIsKeptWhenItFits() async throws {
        // Omny/Triton served 37,159,200 bytes after HEAD reported 30,886,420, and the download was discarded.
        let fixture = try makeFixture()
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
        let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:ads", byteCount: 1)
        let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "ads",
            reservationId: reservation.id, userInitiated: true)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
            remoteURL: "https://example.com/audio", state: .downloading))
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
        let staged = fixture.root.appending(path: "ads.mp3")
        try Data([1, 2, 3]).write(to: staged)
        await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: true)
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "episode"))
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
        coordinator.shutdown()
    }

    // #541: the committed row carried the protection captured before `ledger.commit`. If the
    // listener started the episode while the commit waited, the new file was left unprotected.
    func testEpisodeStartedWhileItsDownloadCommitsIsProtectedFromEviction() async throws {
        let fixture = try makeFixture()
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 10))
        let fileManager = ReconcileHookFileManager()
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support, fileManager: fileManager)
        let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:commit", byteCount: 1)
        let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "commit",
            reservationId: reservation.id, userInitiated: true)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
            remoteURL: "https://example.com/audio", state: .downloading))
        // A row recorded larger than its file puts the budget over, so the commit's overflow
        // reservation reconciles with the disk; the hook runs inside that file check.
        let prepared = fixture.support.appending(path: "PreparedAudio")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: prepared.appending(path: "other.m4a"))
        try fixture.store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "asset-other", category: .preparedAudio, relativePath: "PreparedAudio/other.m4a",
            byteCount: 20, isReproducible: true
        ))
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
        XCTAssertTrue(coordinator.restoreAttempt(attempt))
        fileManager.onCheck = {
            // The ledger runs off the main actor, which is free while finishDownload awaits it.
            DispatchQueue.main.sync { MainActor.assumeIsolated { coordinator.configureActiveItem("episode") } }
        }
        let staged = fixture.root.appending(path: "commit.mp3")
        try Data([1, 2, 3]).write(to: staged)

        await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: true)

        XCTAssertTrue(fileManager.didFire, "playback started while the commit waited on the ledger")
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        let row = try XCTUnwrap(fixture.store.loadOwnedOfflineAssets().first { $0.id == "podcast-offline-episode" })
        XCTAssertEqual(row.protections, [.activePlayback], "the playing episode's new file is protected")
        coordinator.shutdown()
    }

    private func waitForStarts(_ count: Int, starts: () -> Int) async throws {
        for _ in 0..<100 where starts() < count { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(starts(), count)
    }

    // Keep SQLite files until the test process exits: URLSession callbacks may
    // retain the store after a test returns. Unlinking an open WAL corrupts fixtures.
    private func makeFixture() throws -> (root: URL, support: URL, store: SQLiteSessionStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: "podcast-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        return (root, support, store)
    }
}

private actor DownloadHeadGate {
    private var continuation: CheckedContinuation<Int64, Never>?
    func length() async -> Int64 { await withCheckedContinuation { continuation = $0 } }
    func waitUntilRequested() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ value: Int64) { continuation?.resume(returning: value); continuation = nil }
}

/// Runs a hook the first time the ledger checks `other.m4a`, inside `reconcileWithDisk`.
private final class ReconcileHookFileManager: FileManager, @unchecked Sendable {
    var onCheck: (@Sendable () -> Void)?
    private(set) var didFire = false

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if !didFire, let hook = onCheck, path.hasSuffix("other.m4a") {
            didFire = true
            hook()
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
}
