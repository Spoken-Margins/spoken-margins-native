import AVFoundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #685: the UI-test recorder leaves a real, playable Margin file, so J3 can
/// replay a Margin before and after a relaunch.
final class UITestingToneRecordingClientTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appending(path: "ui-test-recorder-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    func testFinishingWritesADecodableFileAsLongAsTheRecording() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let recorder = UITestingToneRecordingClient(supportDirectory: support, now: { clock })
        try recorder.beginRecording()
        clock += 10
        let path = try recorder.finishRecording(audioRef: nil)

        XCTAssertTrue(path.hasPrefix("SpokenMargins/interjections/"), path)
        XCTAssertTrue(path.hasSuffix(".m4a"), path)
        let file = try AVAudioFile(forReading: support.appending(path: path))
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 10, accuracy: 0.2)
    }

    func testEachRecordingGetsItsOwnFile() throws {
        let recorder = UITestingToneRecordingClient(supportDirectory: support)
        try recorder.beginRecording()
        let first = try recorder.finishRecording(audioRef: nil)
        try recorder.beginRecording()
        let second = try recorder.finishRecording(audioRef: nil)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appending(path: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appending(path: second).path))
    }

    func testCancellingWritesNothing() throws {
        let recorder = UITestingToneRecordingClient(supportDirectory: support)
        try recorder.beginRecording()
        try recorder.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: "SpokenMargins").path))
        XCTAssertThrowsError(try recorder.finishRecording(audioRef: nil))
    }
}
