import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class PodcastDownloadCoordinatorTests: XCTestCase {
    func testRegistrationPersistsSecureDownloadTransportForExistingHTTPEnclosure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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

        coordinator.removeItem("episode")

        XCTAssertNil(try fixture.store.loadPodcastDownload(itemId: "episode"))
        XCTAssertTrue(try fixture.store.loadAudioAssets(itemId: "episode").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testValidatedLocalURLRequiresAvailableNonemptyFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
    }

    private func makeFixture() throws -> (root: URL, support: URL, store: SQLiteSessionStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: "podcast-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        return (root, support, store)
    }
}
