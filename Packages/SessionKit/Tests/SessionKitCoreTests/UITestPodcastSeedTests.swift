import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

final class UITestPodcastSeedTests: XCTestCase {
    func testPodcastEnvironmentAloneDoesNotTouchLibraryOrFiles() throws {
        try withStore { store, directory in
            let original = Item(id: "existing", title: "Existing library", mediaType: "text",
                                text: "Keep this", externalReference: nil, status: "ready")
            try store.saveItem(original)
            let seeded = try UITestPodcastSeed.installIfRequested(
                arguments: ["SpokenMarginsApp"],
                environment: [UITestPodcastSeed.environmentKey: "1"], store: store,
                fixtureURL: { XCTFail("Normal launch looked up a test fixture"); throw CocoaError(.fileReadNoSuchFile) },
                applicationSupportDirectory: { XCTFail("Normal launch touched the audio cache"); return directory }
            )
            XCTAssertFalse(seeded)
            XCTAssertEqual(try store.listItems(), [original])
            XCTAssertTrue(try store.loadPodcastDownloads().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "PodcastAudio").path))
        }
    }

    func testUITestingWithoutPodcastOptInDoesNotSeed() throws {
        try withStore { store, directory in
            for environment in [[:], [UITestPodcastSeed.environmentKey: "0"]] {
                XCTAssertFalse(try UITestPodcastSeed.installIfRequested(
                    arguments: ["--ui-testing"], environment: environment, store: store,
                    fixtureURL: { XCTFail("Unrequested fixture was read"); throw CocoaError(.fileReadNoSuchFile) },
                    applicationSupportDirectory: { directory }
                ))
            }
            XCTAssertTrue(try store.listItems().isEmpty)
        }
    }

    func testRequestedSeedCopiesSmallFixtureAndPersistsOfflineEpisodeAcrossReopen() throws {
        try withStore { store, directory in
            try store.saveItem(Item(id: "old-test", title: "Old seed", mediaType: "text",
                                    text: "Old", externalReference: nil, status: "ready"))
            let fixture = fixtureURL()
            let fixtureData = try Data(contentsOf: fixture)
            XCTAssertLessThan(fixtureData.count, 1_000_000)
            XCTAssertFalse(fixtureData.starts(with: Data("version https://git-lfs.github.com".utf8)))
            XCTAssertTrue(try UITestPodcastSeed.installIfRequested(
                arguments: ["--ui-testing"], environment: [UITestPodcastSeed.environmentKey: "1"],
                store: store, fixtureURL: { fixture }, applicationSupportDirectory: { directory }
            ), "J2 needs an offline seed rather than the default text seed")
            let reopened = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
            let item = try XCTUnwrap(reopened.loadItem(id: UITestPodcastSeed.itemID))
            XCTAssertEqual(try reopened.listItems().map(\.id), [UITestPodcastSeed.itemID])
            XCTAssertEqual(item.mediaType, "podcast")
            XCTAssertEqual(item.media?.sourceType, .remoteStream)
            XCTAssertEqual(item.media?.durationMs, UITestPodcastSeed.durationMs)
            let record = try XCTUnwrap(reopened.loadPodcastDownload(itemId: item.id))
            XCTAssertEqual(record.state, .availableOffline)
            XCTAssertEqual(record.remoteURL, item.media?.url)
            XCTAssertEqual(record.bytesWritten, Int64(fixtureData.count))
            let relativePath = try XCTUnwrap(record.localRelativePath)
            XCTAssertEqual(try Data(contentsOf: directory.appending(path: "PodcastAudio").appending(path: relativePath)),
                           fixtureData, "The real enclosure must survive process reconstruction")
        }
    }

    func testMissingFixtureFailsBeforeResettingLibrary() throws {
        try withStore { store, directory in
            let original = Item(id: "existing", title: "Existing", mediaType: "text",
                                text: "Keep", externalReference: nil, status: "ready")
            try store.saveItem(original)
            XCTAssertThrowsError(try UITestPodcastSeed.installIfRequested(
                arguments: ["--ui-testing"], environment: [UITestPodcastSeed.environmentKey: "1"],
                store: store, fixtureURL: { directory.appending(path: "missing.mp3") },
                applicationSupportDirectory: { directory }
            ))
            XCTAssertEqual(try store.listItems(), [original])
        }
    }

    private func withStore(_ body: (SQLiteSessionStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "j2-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        try body(store, directory)
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Contracts/fixtures/audio/\(UITestPodcastSeed.fixtureName).mp3")
    }
}
