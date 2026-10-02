import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

final class UITestingSeedTests: XCTestCase {
    private let environment = [
        "SPOKEN_MARGINS_UI_TEST_RECORDING": "1",
        "SPOKEN_MARGINS_UI_TEST_PODCAST": "1",
        "SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT": "A seeded article"
    ]

    func testHooksAreInertWithoutUITestingArgument() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var hooks = environment
        hooks["SPOKEN_MARGINS_UI_TEST_PRESERVE_LIBRARY"] = "1"
        let configuration = UITestingSeedConfiguration(arguments: [], environment: hooks)
        XCTAssertFalse(configuration.usesFixtureRecording)
        XCTAssertFalse(configuration.preservesLibrary)
        XCTAssertFalse(configuration.seedsLibrary)
        XCTAssertNil(configuration.sourceText)
        let missingFixture = directory.appending(path: "missing.mp3")
        let missingSupport = directory.appending(path: "untouched")
        XCTAssertNil(configuration.makeRecordingClient(fixtureURL: missingFixture, applicationSupportDirectory: missingSupport))
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        let existing = Item(id: "owner-item", title: "Keep me", mediaType: "text", text: "Existing data", externalReference: nil, status: "ready")
        try store.saveItem(existing)
        XCTAssertNil(try UITestingOfflinePodcastSeed.install(
            configuration: configuration, store: store,
            fixtureURL: missingFixture, applicationSupportDirectory: missingSupport
        ))
        XCTAssertEqual(try store.listItems().map(\.id), [existing.id])
        XCTAssertTrue(try store.loadPodcastDownloads().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSupport.path))
    }

    func testUITestingArgumentAloneDoesNotEnableHooks() throws {
        let configuration = UITestingSeedConfiguration(arguments: ["--ui-testing"], environment: [:])
        XCTAssertFalse(configuration.usesFixtureRecording)
        XCTAssertFalse(configuration.seedsLibrary)
    }

    func testPreservingLibraryOnUITestingRelaunchDisablesReseeding() throws {
        var hooks = environment
        hooks["SPOKEN_MARGINS_UI_TEST_PRESERVE_LIBRARY"] = "1"
        let configuration = UITestingSeedConfiguration(arguments: ["--ui-testing"], environment: hooks)
        XCTAssertTrue(configuration.preservesLibrary)
        XCTAssertFalse(configuration.seedsLibrary, "Relaunch must not erase the saved Margin")
        XCTAssertTrue(configuration.usesFixtureRecording)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        let existing = Item(id: "saved-item", title: "Keep on relaunch", mediaType: "text",
                            text: "Existing data", externalReference: nil, status: "ready")
        try store.saveItem(existing)
        XCTAssertNil(try UITestingOfflinePodcastSeed.install(
            configuration: configuration, store: store,
            fixtureURL: directory.appending(path: "missing.mp3"),
            applicationSupportDirectory: directory.appending(path: "untouched")
        ))
        XCTAssertEqual(try store.listItems().map(\.id), [existing.id])
    }

    func testRecordingHookSavesARealFileThatSurvivesClientRecreation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = fixtureURL()
        let configuration = UITestingSeedConfiguration(arguments: ["--ui-testing"], environment: environment)
        var recorder = try XCTUnwrap(configuration.makeRecordingClient(fixtureURL: fixture, applicationSupportDirectory: directory))
        try recorder.beginRecording()
        let path = try recorder.finishRecording(audioRef: "interjections/do-not-overwrite.mp3")
        XCTAssertTrue(path.hasPrefix("interjections/ui-test-"))
        let savedURL = directory.appending(path: "SpokenMargins").appending(path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path),
                      "UI-test recording must create the file persisted on the Margin, not just name it")
        XCTAssertEqual(try Data(contentsOf: savedURL), try Data(contentsOf: fixture))
        recorder = try XCTUnwrap(configuration.makeRecordingClient(fixtureURL: fixture, applicationSupportDirectory: directory))
        // Creating/cancelling a later capture must not delete a saved Margin.
        try recorder.beginRecording()
        try recorder.cancelRecording()
        XCTAssertEqual(try Data(contentsOf: savedURL), try Data(contentsOf: fixture))
        XCTAssertThrowsError(try recorder.finishRecording(audioRef: nil))
        try recorder.beginRecording()
        let secondPath = try recorder.finishRecording(audioRef: nil)
        XCTAssertNotEqual(path, secondPath)
        XCTAssertEqual(try Data(contentsOf: savedURL), try Data(contentsOf: fixture))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: savedURL.deletingLastPathComponent().path).count, 2)
    }

    func testPodcastSeedUsesRealOfflineFileAndReopensFromSQLite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "library.sqlite")
        let configuration = UITestingSeedConfiguration(arguments: ["--ui-testing"], environment: environment)
        let store = try SQLiteSessionStore(path: database.path)
        let item = try XCTUnwrap(UITestingOfflinePodcastSeed.install(
            configuration: configuration, store: store,
            fixtureURL: fixtureURL(), applicationSupportDirectory: directory
        ))
        XCTAssertEqual(item.media?.sourceType, .remoteStream)
        XCTAssertEqual(item.media?.durationMs, UITestingOfflinePodcastSeed.durationMs)
        let reopened = try SQLiteSessionStore(path: database.path)
        XCTAssertEqual(try reopened.loadItem(id: item.id), item)
        let record = try XCTUnwrap(reopened.loadPodcastDownloads().first)
        XCTAssertEqual(record.state, .availableOffline)
        XCTAssertEqual(record.remoteURL, item.media?.url)
        let path = try XCTUnwrap(record.localRelativePath)
        let episode = try Data(contentsOf: directory.appending(path: "PodcastAudio").appending(path: path))
        let fixture = try Data(contentsOf: fixtureURL())
        XCTAssertEqual(record.bytesWritten, Int64(episode.count))
        XCTAssertEqual(episode.count, fixture.count * 12)
        for start in stride(from: 0, to: episode.count, by: fixture.count) {
            XCTAssertEqual(episode.subdata(in: start..<(start + fixture.count)), fixture)
        }
    }

    func testFixtureContainsTenSecondsOfCompleteMP3FramesUnderOneMB() throws {
        let data = try Data(contentsOf: fixtureURL())
        XCTAssertLessThan(data.count, 1_000_000)
        // MPEG-1 Layer III, 128 kb/s, 48 kHz, no padding: 384-byte frames,
        // 1152 samples per frame. No stale Xing duration/tag survives the extract.
        XCTAssertEqual(data.count, 417 * 384)
        for offset in stride(from: 0, to: data.count, by: 384) {
            XCTAssertEqual(data[offset], 0xff)
            XCTAssertEqual(data[offset + 1] & 0xfe, 0xfa)
            XCTAssertEqual(data[offset + 2], 0x94)
        }
        let milliseconds = (data.count / 384) * 1152 * 1000 / 48000
        XCTAssertEqual(milliseconds, 10_008)
        XCTAssertEqual(milliseconds * 12, UITestingOfflinePodcastSeed.durationMs)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ui-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Contracts/fixtures/audio/ui-test-margin.mp3")
    }
}
