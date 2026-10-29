import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #2507 / #2509 / #2510: finishing a podcast download checks and moves the staged file and saves its rows off
/// the main actor. These run the two steps on real files and a real database.
final class PodcastDownloadAdoptionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "podcast-download-adoption-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func staged(_ name: String, _ data: Data) throws -> URL {
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFB, 0x90, 0x00])

    func testAudioIsMovedAndItsSizeReturned() throws {
        let source = try staged("staging.mp3", audio)
        let destination = root.appending(path: "gen.mp3")

        let size = try PodcastDownloadAdoption.adopt(stagedURL: source, responseOK: true, to: destination)

        XCTAssertEqual(size, Int64(audio.count))
        XCTAssertEqual(try Data(contentsOf: destination), audio)
        XCTAssertFalse(exists(source), "moved, not copied")
    }

    func testAPageOfTextIsRefusedAndTheStagedFileRemoved() throws {
        let source = try staged("staging.mp3", Data("<html><body>Sign in to continue</body></html>".utf8))
        let destination = root.appending(path: "gen.mp3")

        XCTAssertThrowsError(try PodcastDownloadAdoption.adopt(stagedURL: source, responseOK: true, to: destination)) {
            XCTAssertEqual($0 as? PodcastDownloadFailure, .notAudio)
        }
        XCTAssertFalse(exists(source))
        XCTAssertFalse(exists(destination))
    }

    func testANon2xxResponseIsRefusedEvenWithAudioInIt() throws {
        let source = try staged("staging.mp3", audio)
        let destination = root.appending(path: "gen.mp3")

        XCTAssertThrowsError(try PodcastDownloadAdoption.adopt(stagedURL: source, responseOK: false, to: destination))
        XCTAssertFalse(exists(source), "the staged file is gone")
        XCTAssertFalse(exists(destination))
    }

    func testAnEmptyOrMissingFileIsRefused() throws {
        let empty = try staged("empty.mp3", Data())
        let destination = root.appending(path: "gen.mp3")
        XCTAssertThrowsError(try PodcastDownloadAdoption.adopt(stagedURL: empty, responseOK: true, to: destination))
        XCTAssertFalse(exists(empty))
        XCTAssertThrowsError(try PodcastDownloadAdoption.adopt(stagedURL: nil, responseOK: true, to: destination))
        XCTAssertThrowsError(try PodcastDownloadAdoption.adopt(
            stagedURL: root.appending(path: "never-written.mp3"), responseOK: true, to: destination))
        XCTAssertFalse(exists(destination))
    }

    func testAFailedMoveLeavesNothingStaged() throws {
        let source = try staged("staging.mp3", audio)
        let blocked = root.appending(path: "no-such-folder/gen.mp3")

        XCTAssertThrowsError(try PodcastDownloadAdoption.adopt(stagedURL: source, responseOK: true, to: blocked))
        XCTAssertFalse(exists(source))
    }

    func testPublishSavesTheAssetAndTheRow() throws {
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let asset = AudioAsset(id: "podcast-local-episode", itemId: "episode", audioSourceType: .nativeMediaFile,
                               availability: .localPhone, filePath: "gen.mp3")
        let record = PodcastDownloadRecord(id: "podcast-download-episode", itemId: "episode",
                                           remoteURL: "https://example.com/a.mp3", localRelativePath: "gen.mp3",
                                           state: .availableOffline, bytesWritten: 14, expectedBytes: 14)

        try PodcastDownloadAdoption.publish(asset: asset, record: record, in: store)

        XCTAssertEqual(try store.loadAudioAssets(itemId: "episode").map(\.id), ["podcast-local-episode"])
        XCTAssertEqual(try store.loadPodcastDownload(itemId: "episode")?.state, .availableOffline)
    }
}
