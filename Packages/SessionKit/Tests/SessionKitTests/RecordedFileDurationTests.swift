#if canImport(AVFoundation)
import XCTest
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

        let milliseconds = try XCTUnwrap(RecordedFileDuration.milliseconds(of: url))

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

        let shortMs = try XCTUnwrap(RecordedFileDuration.milliseconds(of: short))
        let longMs = try XCTUnwrap(RecordedFileDuration.milliseconds(of: long))

        XCTAssertGreaterThan(longMs, shortMs + 3_000)
    }

    func testAMissingOrEmptyFileHoldsNothingToKeep() throws {
        let missing = temporaryURL()
        XCTAssertNil(RecordedFileDuration.milliseconds(of: missing))

        let empty = temporaryURL()
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        XCTAssertNil(RecordedFileDuration.milliseconds(of: empty))
    }
}
#endif
