#if canImport(AVFoundation)
import XCTest
import SessionKit
@testable import SessionKitAudio

/// #937: a stopped recorder reads 0 and a poll can be old, so the length of a finished recording is read
/// from the file before anything deletes it.
final class RecordedFileDurationTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "recorded-duration-\(UUID().uuidString).m4a")
    }

    func testAFinishedRecordingReportsTheAudioItHolds() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try SeededNoiseAudio.write(to: url, seconds: 3)

        guard case .milliseconds(let milliseconds) = RecordedFileDuration.measure(url) else {
            return XCTFail("a finished recording must measure")
        }

        XCTAssertEqual(Double(milliseconds), 3_000, accuracy: 250)
    }

    func testALongerRecordingReportsMore() throws {
        let short = temporaryURL()
        let long = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: short)
            try? FileManager.default.removeItem(at: long)
        }
        try SeededNoiseAudio.write(to: short, seconds: 1)
        try SeededNoiseAudio.write(to: long, seconds: 5)

        guard case .milliseconds(let shortMs) = RecordedFileDuration.measure(short),
              case .milliseconds(let longMs) = RecordedFileDuration.measure(long) else {
            return XCTFail("both recordings must measure")
        }

        XCTAssertGreaterThan(longMs, shortMs + 3_000)
    }

    func testAMissingOrEmptyFileHoldsNothingToKeep() throws {
        XCTAssertEqual(RecordedFileDuration.measure(temporaryURL()), .milliseconds(0))

        let empty = temporaryURL()
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        XCTAssertEqual(RecordedFileDuration.measure(empty), .milliseconds(0))
    }

    func testAFileThatHasBytesButWillNotOpenIsUnreadableNeverEmpty() throws {
        // Audit round 3 on #939: a read that fails is unknown, not empty, so the caller keeps the file.
        let damaged = temporaryURL()
        defer { try? FileManager.default.removeItem(at: damaged) }
        try Data(repeating: 0x5A, count: 4_096).write(to: damaged)

        XCTAssertEqual(RecordedFileDuration.measure(damaged), .unreadable)
    }

    func testTheMeasurementRunsOffTheMainThreadAndTheOutcomeAppearsWithoutWaiting() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try SeededNoiseAudio.write(to: url, seconds: 2)

        let measurement = StoppedFileMeasurement.start(url: url)
        let deadline = Date().addingTimeInterval(10)
        while measurement.outcome == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }

        guard case .milliseconds(let milliseconds)? = measurement.outcome else {
            return XCTFail("the measurement did not finish")
        }
        XCTAssertEqual(Double(milliseconds), 2_000, accuracy: 250)
    }

    /// #1041: a restart never reads the file on the main thread. A recorder that had already stopped is
    /// restarted only once the poll's background measurement has landed and shows nothing worth keeping.
    func testARestartOverAnUnfinishedOrUnreadableMeasurementKeepsTheFile() {
        XCTAssertEqual(CaptureRestartGuard.verdict(capturedMs: 22, recorderHadStopped: true, measurement: nil), .keepUnknown)
        XCTAssertEqual(CaptureRestartGuard.verdict(capturedMs: 22, recorderHadStopped: true, measurement: .unreadable), .keepUnknown)
        XCTAssertEqual(CaptureRestartGuard.verdict(capturedMs: 22, recorderHadStopped: true, measurement: .milliseconds(22)), .restart)
        XCTAssertEqual(
            CaptureRestartGuard.verdict(capturedMs: 22, recorderHadStopped: true, measurement: .milliseconds(MarginCaptureTimings.keepAudioMs)),
            .keepAudio,
            "the file holds more than the polls saw"
        )
    }

    func testARunningRecorderIsJudgedByWhatItHasTakenIn() {
        XCTAssertEqual(CaptureRestartGuard.verdict(capturedMs: 22, recorderHadStopped: false, measurement: nil), .restart)
        XCTAssertEqual(
            CaptureRestartGuard.verdict(capturedMs: MarginCaptureTimings.keepAudioMs, recorderHadStopped: false, measurement: nil),
            .keepAudio
        )
        XCTAssertEqual(CaptureRestartGuard.verdict(capturedMs: 249, recorderHadStopped: false, measurement: .unreadable), .restart)
    }
}
#endif
