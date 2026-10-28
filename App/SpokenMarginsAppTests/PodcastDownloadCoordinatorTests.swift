import AVFoundation
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
        coordinator.flushPendingRowWritesForTesting()

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
        coordinator.flushPendingRowWritesForTesting()
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
        coordinator.flushPendingRowWritesForTesting()

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
        coordinator.flushPendingRowWritesForTesting()

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
        coordinator.flushPendingRowWritesForTesting()
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
        coordinator.flushPendingRowWritesForTesting()
        coordinator.shutdown()

        let restored = try PodcastDownloadCoordinator(
            store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false
        )
        XCTAssertEqual(restored.validatedLocalURL(for: "episode"), saved)
        restored.shutdown()
    }

    /// #936: Download Again tapped while a copy is already coming down must not cancel it and start over.
    func testDownloadAgainWhileDownloadingDoesNotRestartTheDownload() async throws {
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
        let head = DownloadHeadGate()
        let coordinator = try PodcastDownloadCoordinator(
            store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false,
            contentLength: { _, _ in await head.length() }, startDownload: { _, _ in }
        )

        coordinator.redownload(itemId: "episode")
        await head.waitUntilRequested()
        XCTAssertEqual(coordinator.status(itemId: "episode"), .downloading)
        let retriesAfterFirstTap = coordinator.recordsByItemId["episode"]?.retryCount

        coordinator.redownload(itemId: "episode")
        coordinator.redownload(itemId: "episode")
        let preparation = try XCTUnwrap(coordinator.preparationTasks["episode"])

        XCTAssertEqual(coordinator.recordsByItemId["episode"]?.retryCount, retriesAfterFirstTap,
                       "Extra taps must not count as new attempts")
        XCTAssertEqual(coordinator.status(itemId: "episode"), .downloading)
        await head.finish(8)
        await preparation.value
        let requests = await head.requests
        XCTAssertEqual(requests, 1, "Extra taps must not ask for the file's size again, which means starting over")
        XCTAssertEqual(coordinator.validatedLocalURL(for: "episode"), saved, "The saved copy stays playable meanwhile")
        coordinator.shutdown()
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
        coordinator.flushPendingRowWritesForTesting()
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
        coordinator.flushPendingRowWritesForTesting()
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
        coordinator.flushPendingRowWritesForTesting()
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
        coordinator.flushPendingRowWritesForTesting()
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
        XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().first?.protections, [],
                       "nothing is playing, so the committed protection is removed (#541)")
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

    /// #919: a 200 whose body is a sign-in page or an error message is not the episode. It must not
    /// replace the saved audio, and it must not be marked available offline as a first download either.
    func testAWebPageDoesNotReplaceAWorkingEpisode() async throws {
        for (name, body) in Self.responsesThatAreNotAudio {
            let fixture = try makeFixture()
            let directory = fixture.support.appending(path: "PodcastAudio")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let wav = Self.wavData()
            let saved = directory.appending(path: "saved.wav")
            try wav.write(to: saved)
            XCTAssertNoThrow(try AVAudioFile(forReading: saved), "\(name): the saved episode plays before the download")
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
                remoteURL: "https://example.com/audio", localRelativePath: saved.lastPathComponent, state: .downloading,
                bytesWritten: 0, expectedBytes: Int64(wav.count)))
            let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
            let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:page", byteCount: Int64(body.count))
            let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "page",
                reservationId: reservation.id, userInitiated: true)
            let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
                applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
            XCTAssertTrue(coordinator.restoreAttempt(attempt), name)
            var published = false
            coordinator.onLocalAssetReady = { _, _ in published = true }
            let staged = fixture.root.appending(path: "page.mp3")
            try body.write(to: staged)

            await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: true)

            XCTAssertFalse(published, name)
            XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline, name)
            XCTAssertEqual(coordinator.validatedLocalURL(for: "episode"), saved, name)
            XCTAssertEqual(try Data(contentsOf: saved), wav, "\(name): the saved episode is untouched")
            XCTAssertNoThrow(try AVAudioFile(forReading: saved), "\(name): and still plays")
            let reason = coordinator.recordsByItemId["episode"]?.failureReason ?? ""
            XCTAssertTrue(reason.contains("web page or text"), "\(name): \(reason)")
            XCTAssertTrue(reason.contains("saved audio is still available"), "\(name): \(reason)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["saved.wav"],
                           "\(name): the page was not kept next to the episode")
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), name)
            XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty, name)
            XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty, name)
            coordinator.shutdown()
        }
    }

    func testAWebPageIsNotAFirstDownloadEither() async throws {
        for (name, body) in Self.responsesThatAreNotAudio {
            let fixture = try makeFixture()
            let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
            let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:first", byteCount: Int64(body.count))
            let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "first",
                reservationId: reservation.id, userInitiated: true)
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
                remoteURL: "https://example.com/audio", state: .downloading))
            let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
                applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
            XCTAssertTrue(coordinator.restoreAttempt(attempt), name)
            var published = false
            coordinator.onLocalAssetReady = { _, _ in published = true }
            let staged = fixture.root.appending(path: "page.mp3")
            try body.write(to: staged)

            await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: true)

            XCTAssertFalse(published, name)
            XCTAssertEqual(coordinator.status(itemId: "episode"), .failed, name)
            XCTAssertNil(coordinator.validatedLocalURL(for: "episode"), name)
            XCTAssertTrue(coordinator.recordsByItemId["episode"]?.failureReason?.contains("web page or text") == true, name)
            XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty, name)
            XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty, name)
            XCTAssertTrue(try fixture.store.loadAudioAssets(itemId: "episode").isEmpty, name)
            coordinator.shutdown()
        }
    }

    /// The other side of #919: real audio is still adopted. Without this, a check that refuses
    /// everything would pass the two tests above.
    func testRealAudioIsStillAdoptedAsADownload() async throws {
        let fixture = try makeFixture()
        let wav = Self.wavData()
        let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
        let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:audio", byteCount: Int64(wav.count))
        let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "audio",
            reservationId: reservation.id, userInitiated: true)
        try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
            remoteURL: "https://example.com/audio", state: .downloading))
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
        XCTAssertTrue(coordinator.restoreAttempt(attempt))
        var published: URL?
        coordinator.onLocalAssetReady = { _, url in published = url }
        let staged = fixture.root.appending(path: "episode.wav")
        try wav.write(to: staged)

        await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: true)

        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        let local = try XCTUnwrap(coordinator.validatedLocalURL(for: "episode"))
        XCTAssertEqual(published, local)
        XCTAssertEqual(try Data(contentsOf: local), wav)
        XCTAssertNoThrow(try AVAudioFile(forReading: local))
        XCTAssertNil(coordinator.recordsByItemId["episode"]?.failureReason)
        coordinator.shutdown()
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

    // #912: the download needed a HEAD answer with a positive Content-Length, so a host that refuses HEAD
    // (403, 405) or leaves the length out could never be downloaded. Each row is served by a URLProtocol
    // that answers audio on GET, and each must download, hold the reservation the host's answer allows,
    // and keep the file within the storage budget.
    func testHostsThatRefuseHeadOrLeaveOutTheLengthStillDownloadWithinTheBudget() async throws {
        let unannouncedBudget: Int64 = 1_000
        let audio = Self.wavData(seconds: 0.025)
        let audioBytes = Int64(audio.count)
        let rows: [(path: String, reserved: Int64, announced: Int64?, requests: [String], note: String)] = [
            ("/head-405.mp3", audioBytes, audioBytes, ["HEAD /head-405.mp3", "GET /head-405.mp3 range"],
             "HEAD refused: the size comes from Content-Range on a one-byte ranged GET"),
            ("/head-no-length.mp3", audioBytes, audioBytes, ["HEAD /head-no-length.mp3", "GET /head-no-length.mp3 range"],
             "HEAD without a length: a host that ignores the range sends the whole file's length"),
            ("/head-ok.mp3", audioBytes, audioBytes, ["HEAD /head-ok.mp3"],
             "HEAD announces the length: no second size probe"),
            ("/announces-nothing.mp3", unannouncedBudget, nil, ["HEAD /announces-nothing.mp3", "GET /announces-nothing.mp3 range"],
             "no size anywhere: reserve the bounded amount, never more than the budget holds"),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for row in rows {
            DownloadProbeURLProtocol.reset(audio: audio, holdsDownloads: true)
            let fixture = try makeFixture()
            try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: unannouncedBudget))
            let coordinator = try PodcastDownloadCoordinator(store: fixture.store,
                applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false,
                usesBackgroundSession: false, preflightSession: session,
                foregroundSessionConfiguration: configuration)
            defer {
                DownloadProbeURLProtocol.releaseDownloads()
                coordinator.shutdown()
            }
            coordinator.setNetworkTransportForTesting(.wifi)
            coordinator.register(itemId: "episode", remoteURL: URL(string: "https://probe.example.com\(row.path)")!,
                                 userInitiated: true)
            let preparation = try XCTUnwrap(coordinator.preparationTasks["episode"], row.note)
            await preparation.value
            let requests = row.requests + ["GET \(row.path)"]
            for _ in 0..<200 where DownloadProbeURLProtocol.requests.count < requests.count {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(DownloadProbeURLProtocol.requests, requests, "the real download GET follows the probes: \(row.note)")
            XCTAssertEqual(try fixture.store.loadOfflineStorageReservations().map(\.byteCount), [row.reserved], row.note)
            XCTAssertEqual(coordinator.recordsByItemId["episode"]?.expectedBytes, row.announced, row.note)
            XCTAssertEqual(coordinator.status(itemId: "episode"), .downloading, row.note)

            // The server held the GET body while the reservation was checked. Let URLSession write its
            // own temporary file and deliver didFinishDownloadingTo; only that delegate may commit it.
            DownloadProbeURLProtocol.releaseDownloads()
            for _ in 0..<200 where coordinator.status(itemId: "episode") == .downloading {
                try await Task.sleep(for: .milliseconds(25))
            }

            XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline, row.note)
            let local = try XCTUnwrap(coordinator.validatedLocalURL(for: "episode"), row.note)
            XCTAssertEqual(try Data(contentsOf: local), audio, "the real response, not a manufactured staged file")
            XCTAssertGreaterThan(try AVAudioFile(forReading: local).length, 0, "the downloaded bytes are valid audio")
            XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().map(\.byteCount), [audioBytes], row.note)
            XCTAssertLessThanOrEqual(audioBytes, unannouncedBudget, row.note)
            XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty, row.note)
        }
    }

    func testAnUnannouncedDownloadLargerThanTheBudgetIsRefusedAndLeavesNothingBehind() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProbeURLProtocol.self]
        DownloadProbeURLProtocol.reset(audio: Self.wavData(seconds: 0.15), holdsDownloads: true)
        let fixture = try makeFixture()
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 1_000))
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false,
            usesBackgroundSession: false, preflightSession: session,
            foregroundSessionConfiguration: configuration)
        defer {
            DownloadProbeURLProtocol.releaseDownloads()
            coordinator.shutdown()
        }
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://probe.example.com/announces-nothing.mp3")!,
                             userInitiated: true)
        await coordinator.preparationTasks["episode"]?.value
        for _ in 0..<200 where DownloadProbeURLProtocol.requests.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(DownloadProbeURLProtocol.requests,
                       ["HEAD /announces-nothing.mp3", "GET /announces-nothing.mp3 range", "GET /announces-nothing.mp3"])
        XCTAssertEqual(try fixture.store.loadOfflineStorageReservations().map(\.byteCount), [1_000])
        DownloadProbeURLProtocol.releaseDownloads()
        for _ in 0..<200 where coordinator.status(itemId: "episode") == .downloading {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(coordinator.status(itemId: "episode"), .failed, "the real audio response exceeds the 1,000-byte budget")
        XCTAssertNil(coordinator.validatedLocalURL(for: "episode"))
        XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty)
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.support.appending(path: "PodcastAudio").path).isEmpty,
                      "neither staging nor committed audio remains after refusal")
    }

    func testAHostThatRefusesEverythingFailsBeforeReservingRoomThatCouldEvictOtherAudio() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProbeURLProtocol.self]
        DownloadProbeURLProtocol.reset()
        let fixture = try makeFixture()
        try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 1_000))
        // Another episode fills most of the budget and could be evicted, as a reservation for this one would require.
        let audioDirectory = fixture.support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let other = audioDirectory.appending(path: "other.mp3")
        try Data(repeating: 7, count: 900).write(to: other)
        try fixture.store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "podcast-offline-other", itemId: "other", category: .podcast,
            relativePath: "PodcastAudio/other.mp3", byteCount: 900, isReproducible: true
        ))
        var starts = 0
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false,
            usesBackgroundSession: false, startDownload: { _, _ in starts += 1 },
            preflightSession: URLSession(configuration: configuration))
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "gone", remoteURL: URL(string: "https://probe.example.com/gone.mp3")!,
                             userInitiated: true)
        await coordinator.preparationTasks["gone"]?.value

        XCTAssertEqual(DownloadProbeURLProtocol.requests, ["HEAD /gone.mp3", "GET /gone.mp3 range"])
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(coordinator.status(itemId: "gone"), .failed)
        XCTAssertEqual(coordinator.recordsByItemId["gone"]?.failureReason, "The episode's host refused the download (HTTP 404).")
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty, "nothing was reserved")
        XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().map(\.id), ["podcast-offline-other"],
                       "the other episode was not evicted to make room for one that can't download")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        coordinator.shutdown()
    }

    private static let responsesThatAreNotAudio: [(String, Data)] = [
        ("hotel sign-in page", Data("<!DOCTYPE html><html><body>Sign in to the guest Wi-Fi</body></html>".utf8)),
        ("json error", Data(#"{"error":"forbidden","status":403}"#.utf8)),
        ("xml error", Data(#"<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>"#.utf8)),
    ]

    /// A real PCM WAV (8 kHz, 16-bit, mono) that AVFoundation opens, so "a working episode" here is one that plays.
    private static func wavData(seconds: Double = 0.5) -> Data {
        let sampleRate: UInt32 = 8_000
        var samples = Data()
        for index in 0..<Int(Double(sampleRate) * seconds) {
            let value = Int16((sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 8_000).rounded())
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav.append(le32(UInt32(36 + samples.count)))
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(le32(16))
        wav.append(le16(1))
        wav.append(le16(1))
        wav.append(le32(sampleRate))
        wav.append(le32(sampleRate * 2))
        wav.append(le16(2))
        wav.append(le16(16))
        wav.append(Data("data".utf8))
        wav.append(le32(UInt32(samples.count)))
        wav.append(samples)
        return wav
    }

    // MARK: Test honesty (#1042: APA-03, APA-04, APA-10, APA-11)

    /// APA-03: the older HTTP-failure test used a file the budget rejected anyway, so deleting the status check
    /// still ended `.failed`. Here the file fits: only the status decides.
    func testAnErrorPageThatFitsTheBudgetIsRefusedBecauseOfItsStatusAlone() async throws {
        for httpOK in [false, true] {
            let fixture = try makeFixture()
            try fixture.store.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 10))
            let ledger = OfflineStorageLedger(repository: fixture.store, rootDirectory: fixture.support)
            let reservation = try await ledger.reserve(ownerId: "podcast-download-episode:status", byteCount: 3)
            let attempt = PodcastDownloadAttempt(itemId: "episode", generation: "status",
                reservationId: reservation.id, userInitiated: true)
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(id: "download", itemId: "episode",
                remoteURL: "https://example.com/audio", state: .downloading))
            let coordinator = try PodcastDownloadCoordinator(store: fixture.store, ledger: ledger,
                applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
            var published = false
            coordinator.onLocalAssetReady = { _, _ in published = true }
            coordinator.restoreAttempt(attempt)
            let staged = fixture.root.appending(path: "status.mp3")
            try Data([1, 2, 3]).write(to: staged)

            await coordinator.finishDownload(attempt, stagedURL: staged, responseOK: httpOK)

            let label = httpOK ? "a 2xx response" : "a non-2xx response"
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "\(label): the staged file is gone")
            XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty, "\(label): the reservation is released")
            if httpOK {
                XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline, "control: the same file is adopted")
                XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().count, 1)
                XCTAssertTrue(published)
            } else {
                XCTAssertEqual(coordinator.status(itemId: "episode"), .failed, label)
                XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty, "\(label): nothing is owned")
                XCTAssertNil(coordinator.validatedLocalURL(for: "episode"), label)
                XCTAssertFalse(published, label)
            }
            coordinator.shutdown()
        }
    }

    /// APA-04: the older test delivered the old task's callbacks after the replacement had finished, where the record
    /// state alone rejects them. The cancelled old task really reports while the replacement is still downloading.
    func testACancelledOldAttemptCannotFailAReplacementThatIsStillDownloading() async throws {
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
        XCTAssertNotEqual(old.generation, current.generation)

        coordinator.completeDownload(old, error: URLError(.cancelled))
        let oldFile = fixture.root.appending(path: "old.mp3")
        try Data([9]).write(to: oldFile)
        await coordinator.finishDownload(old, stagedURL: oldFile, responseOK: true)

        XCTAssertEqual(coordinator.status(itemId: "episode"), .downloading, "the replacement is still downloading")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try fixture.store.loadOfflineStorageReservations().map(\.id), [current.reservationId],
                       "only the replacement's reservation is held")
        XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty, "the old bytes were not adopted")

        let newFile = fixture.root.appending(path: "new.mp3")
        try Data([4, 5, 6]).write(to: newFile)
        await coordinator.finishDownload(current, stagedURL: newFile, responseOK: true)
        XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(coordinator.validatedLocalURL(for: "episode"))), Data([4, 5, 6]))
        coordinator.shutdown()
    }

    /// APA-11: the file exists and is not empty but is shorter than what was recorded (an interrupted or half-evicted
    /// write). It must not be offered as the episode.
    func testValidatedLocalURLRejectsATruncatedFile() throws {
        let fixture = try makeFixture()
        let audioDirectory = fixture.support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audioDirectory.appending(path: "truncated.mp3"))
        try Data([1, 2, 3]).write(to: audioDirectory.appending(path: "complete.mp3"))
        try Data([1, 2, 3]).write(to: audioDirectory.appending(path: "unrecorded.mp3"))
        for (itemId, recordedBytes) in [("truncated", Int64(10)), ("complete", 3), ("unrecorded", 0)] {
            try fixture.store.savePodcastDownload(PodcastDownloadRecord(
                id: "download-\(itemId)", itemId: itemId, remoteURL: "https://example.com/\(itemId).mp3",
                localRelativePath: "\(itemId).mp3", state: .availableOffline, bytesWritten: recordedBytes))
        }
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)

        XCTAssertNil(coordinator.validatedLocalURL(for: "truncated"), "3 bytes on disk, 10 recorded")
        let record = coordinator.recordsByItemId["truncated"]
        XCTAssertEqual(record?.state, .failed)
        XCTAssertNil(record?.localRelativePath)
        coordinator.flushPendingRowWritesForTesting()
        XCTAssertEqual(try fixture.store.loadPodcastDownloads().first { $0.itemId == "truncated" }?.state, .failed)
        XCTAssertEqual(record?.failureReason, "Downloaded file is missing or incomplete. Download it again.")
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "complete"), "control: size equals what was recorded")
        XCTAssertNotNil(coordinator.validatedLocalURL(for: "unrecorded"), "control: a record with no size recorded is accepted")
    }

    /// APA-10 (redirect half): the BBC chain that failed App Transport Security is fixed in the delegate as well as
    /// before the request. The delegate had never been called by a test.
    func testRedirectToPlainHTTPIsRewrittenToHTTPSAndHTTPSIsLeftAlone() throws {
        let fixture = try makeFixture()
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store, applicationSupportDirectory: fixture.support,
            cacheLimit: .five, monitorsNetwork: false, usesBackgroundSession: false)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com/start")!)
        defer { session.invalidateAndCancel(); coordinator.shutdown() }

        func redirected(to target: String) throws -> URLRequest? {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/start")!, statusCode: 302,
                httpVersion: nil, headerFields: ["Location": target]))
            var handedBack: URLRequest?
            var called = false
            coordinator.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)) { handedBack = $0; called = true }
            XCTAssertTrue(called, "the delegate always answers the redirect")
            return handedBack
        }

        XCTAssertEqual(try redirected(to: "http://cdn.example.com:80/episode.mp3")?.url?.absoluteString,
                       "https://cdn.example.com/episode.mp3", "plain http becomes https and loses the port 80")
        XCTAssertEqual(try redirected(to: "http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/proto/http/x.mp3")?.url?.absoluteString,
                       "https://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/proto/https/x.mp3",
                       "the BBC media selector is asked for its https redirect chain")
        XCTAssertEqual(try redirected(to: "https://cdn.example.com/episode.mp3")?.url?.absoluteString,
                       "https://cdn.example.com/episode.mp3", "https is handed back as it came")
    }

    /// APA-10 (status half): `finishDownload` takes the response's status as a Bool, and every test passed that Bool
    /// itself, so nothing ran the mapping from a real HTTP status in `didFinishDownloadingTo`. Here URLSession
    /// downloads a real 503 whose body is valid audio that fits the budget: only the status can refuse it.
    func testARealErrorStatusIsRefusedEvenWhenItsBodyIsAudio() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProbeURLProtocol.self]
        DownloadProbeURLProtocol.reset(audio: Self.wavData(seconds: 0.025))
        let fixture = try makeFixture()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let coordinator = try PodcastDownloadCoordinator(store: fixture.store,
            applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false,
            usesBackgroundSession: false, preflightSession: session,
            foregroundSessionConfiguration: configuration)
        defer { coordinator.shutdown() }
        var published = false
        coordinator.onLocalAssetReady = { _, _ in published = true }
        coordinator.setNetworkTransportForTesting(.wifi)
        coordinator.register(itemId: "episode", remoteURL: URL(string: "https://probe.example.com/error-503.mp3")!,
                             userInitiated: true)
        await coordinator.preparationTasks["episode"]?.value
        for _ in 0..<200 where coordinator.status(itemId: "episode") == .downloading {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(DownloadProbeURLProtocol.requests, ["HEAD /error-503.mp3", "GET /error-503.mp3"],
                       "the episode was really downloaded")
        XCTAssertEqual(coordinator.status(itemId: "episode"), .failed, "a 503 is not the episode, whatever its body holds")
        XCTAssertNil(coordinator.validatedLocalURL(for: "episode"))
        XCTAssertFalse(published, "nothing is offered to the player")
        XCTAssertTrue(try fixture.store.loadOwnedOfflineAssets().isEmpty, "nothing is owned")
        XCTAssertTrue(try fixture.store.loadOfflineStorageReservations().isEmpty, "the reservation is released")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.support.appending(path: "PodcastAudio").path).isEmpty,
                      "the error response's body is not kept")
    }

    /// APA-10 (#1042), the file-name half: `didFinishDownloadingTo` names the staged file after the response's
    /// suggested file name, keeping its extension only when it is short and letters or digits, and the adopted
    /// episode keeps that extension. No test ran it. Each row is a real URLSession download through the probe host.
    func testTheAdoptedEpisodeKeepsOnlyASafeExtensionFromTheServersFileName() async throws {
        let rows: [(url: String, suggested: String, expected: String, note: String)] = [
            ("https://probe.example.com/name-plain.mp3?download=1", "name-plain.mp3", "mp3",
             "a query string after the file name doesn't hide a normal extension"),
            ("https://probe.example.com/name-query-in-name.mp3", "episode.mp3?dl=1", "audio",
             "punctuation in the extension"),
            ("https://probe.example.com/name-long.mp3", "episode.abcdefghijklmnop", "audio",
             "an extension longer than 10 characters"),
            ("https://probe.example.com/name-bare.mp3", "episode", "audio",
             "no extension"),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let audio = Self.wavData(seconds: 0.025)
        for row in rows {
            // Precondition: the name the sanitizer is handed, as this platform's URL loading derives it from
            // the probe's headers. If the platform names it differently, this says so before the outcome does.
            let url = try XCTUnwrap(URL(string: row.url))
            let served = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                         headerFields: DownloadProbeURLProtocol.namedDownloadHeaders[url.path])
            XCTAssertEqual(served?.suggestedFilename, row.suggested, "precondition: \(row.note)")
            DownloadProbeURLProtocol.reset(audio: audio)
            let fixture = try makeFixture()
            let coordinator = try PodcastDownloadCoordinator(store: fixture.store,
                applicationSupportDirectory: fixture.support, cacheLimit: .five, monitorsNetwork: false,
                usesBackgroundSession: false, preflightSession: session,
                foregroundSessionConfiguration: configuration)
            defer { coordinator.shutdown() }
            coordinator.setNetworkTransportForTesting(.wifi)
            coordinator.register(itemId: "episode", remoteURL: url, userInitiated: true)
            await coordinator.preparationTasks["episode"]?.value
            for _ in 0..<200 where coordinator.status(itemId: "episode") == .downloading {
                try await Task.sleep(for: .milliseconds(25))
            }

            XCTAssertEqual(coordinator.status(itemId: "episode"), .availableOffline, row.note)
            let local = try XCTUnwrap(coordinator.validatedLocalURL(for: "episode"), row.note)
            XCTAssertEqual(local.pathExtension, row.expected, row.note)
            XCTAssertEqual(try Data(contentsOf: local), audio, "the downloaded bytes were adopted: \(row.note)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.support.appending(path: "PodcastAudio").path),
                           [local.lastPathComponent], "only the adopted episode remains: \(row.note)")
        }
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
    private(set) var requests = 0
    func length() async -> Int64 { requests += 1; return await withCheckedContinuation { continuation = $0 } }
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

/// Serves episodes on probe.example.com the way the hosts in #912 do. Each path is one host behaviour:
/// - /head-405.mp3: HEAD is refused (405); a ranged GET answers 206 with the total in Content-Range.
/// - /head-no-length.mp3: HEAD answers 200 with no Content-Length; GET ignores the range and sends 200
///   with the whole file's length.
/// - /head-ok.mp3: HEAD answers 200 with the audio's Content-Length.
/// - /announces-nothing.mp3: HEAD is refused (405); GET answers 200 with no length at all.
/// - /gone.mp3: every request answers 404.
/// - /error-503.mp3: HEAD answers 200 with the audio's Content-Length; GET answers 503 with the audio as its body.
/// - /name-*.mp3: HEAD answers 200 with the audio's Content-Length; GET answers 200 with the audio, under the
///   file name `namedDownloadHeaders` gives that path (#1282).
private final class DownloadProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String] = []
    nonisolated(unsafe) private static var responseAudio = Data(repeating: 7, count: 8)
    nonisolated(unsafe) private static var holdsDownloads = false
    nonisolated(unsafe) private static var pendingDownloads: [(DownloadProbeURLProtocol, Data)] = []

    static func reset(audio: Data = Data(repeating: 7, count: 8), holdsDownloads: Bool = false) {
        lock.withLock {
            seen = []
            responseAudio = audio
            self.holdsDownloads = holdsDownloads
            pendingDownloads = []
        }
    }

    static func releaseDownloads() {
        let pending = lock.withLock {
            holdsDownloads = false
            let pending = pendingDownloads
            pendingDownloads = []
            return pending
        }
        for (transport, body) in pending { transport.deliver(body) }
    }
    /// "HEAD /path" or "GET /path", with " range" when the request asked for a byte range.
    static var requests: [String] { lock.withLock { seen } }

    /// The headers that name each /name-*.mp3 download, as a host's Content-Type and Content-Disposition would.
    /// The odd names are served as octet-stream, so the platform has no audio type to name the file after.
    static let namedDownloadHeaders: [String: [String: String]] = [
        "/name-plain.mp3": ["Content-Type": "audio/mpeg"],
        "/name-query-in-name.mp3": ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"episode.mp3?dl=1\""],
        "/name-long.mp3": ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"episode.abcdefghijklmnop\""],
        "/name-bare.mp3": ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"episode\""],
    ]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "probe.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let ranged = request.value(forHTTPHeaderField: "Range") != nil
        Self.lock.withLock { Self.seen.append("\(method) \(url.path)\(ranged ? " range" : "")") }
        let audio = Self.lock.withLock { Self.responseAudio }
        let status: Int
        // Match the served PCM WAV with its download filename on every platform;
        // the .mp3 scenario URL must not make AVFoundation select an MP3 decoder.
        var headers: [String: String] = [
            "Content-Type": "audio/wav",
            "Content-Disposition": "attachment; filename=\"episode.wav\"",
        ]
        var body = Data()
        if let named = Self.namedDownloadHeaders[url.path] {
            headers = named
        }
        switch (url.path, method) {
        case (let path, "HEAD") where path.hasPrefix("/name-"):
            status = 200
            headers["Content-Length"] = "\(audio.count)"
        case (let path, _) where path.hasPrefix("/name-"):
            status = 200
            body = audio
        case ("/gone.mp3", _):
            status = 404
        case ("/error-503.mp3", "HEAD"):
            status = 200
            headers["Content-Length"] = "\(audio.count)"
        case ("/error-503.mp3", _):
            status = 503
            body = audio
        case ("/head-ok.mp3", "HEAD"):
            status = 200
            headers["Content-Length"] = "\(audio.count)"
        case ("/head-no-length.mp3", "HEAD"):
            status = 200
        case (_, "HEAD"):
            status = 405
        case ("/head-405.mp3", _) where ranged:
            status = 206
            headers["Content-Range"] = "bytes 0-0/\(audio.count)"
            headers["Content-Length"] = "1"
            body = audio.prefix(1)
        case ("/head-no-length.mp3", _):
            status = 200
            headers["Content-Length"] = "\(audio.count)"
            body = audio
        default:
            status = 200
            body = audio
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if method == "GET", !ranged, (200..<300).contains(status) {
            let withheld = Self.lock.withLock {
                guard Self.holdsDownloads else { return false }
                Self.pendingDownloads.append((self, body))
                return true
            }
            if withheld { return }
        }
        deliver(method == "HEAD" ? Data() : body)
    }

    private func deliver(_ body: Data) {
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
