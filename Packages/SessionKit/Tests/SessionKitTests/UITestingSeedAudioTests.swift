#if canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

final class UITestingSeedAudioTests: XCTestCase {
    func testSavedMarginAndOfflinePodcastHaveExpectedMP3DurationAndFormat() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Contracts/fixtures/audio/ui-test-margin.mp3")
        let support = FileManager.default.temporaryDirectory.appending(path: "ui-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let configuration = UITestingSeedConfiguration(arguments: ["--ui-testing"], environment: [
            "SPOKEN_MARGINS_UI_TEST_RECORDING": "1", "SPOKEN_MARGINS_UI_TEST_PODCAST": "1"
        ])
        let recorder = try XCTUnwrap(configuration.makeRecordingClient(fixtureURL: fixture, applicationSupportDirectory: support))
        try recorder.beginRecording()
        let path = try recorder.finishRecording(audioRef: nil)
        try assertMediaMetadata(support.appending(path: "SpokenMargins").appending(path: path), seconds: 10.008)
        let store = try SQLiteSessionStore(path: support.appending(path: "library.sqlite").path)
        _ = try UITestingOfflinePodcastSeed.install(
            configuration: configuration, store: store, fixtureURL: fixture, applicationSupportDirectory: support
        )
        let record = try XCTUnwrap(store.loadPodcastDownloads().first)
        try assertMediaMetadata(support.appending(path: "PodcastAudio").appending(path: XCTUnwrap(record.localRelativePath)), seconds: 120.096)
    }

    private func assertMediaMetadata(_ url: URL, seconds: Double) throws {
        // Inspect the real media file without invoking an encoder, player or
        // speech service. Actual decoded playback remains a Test Desk check.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, seconds, accuracy: 0.1)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEGLayer3)
    }
}
#endif
