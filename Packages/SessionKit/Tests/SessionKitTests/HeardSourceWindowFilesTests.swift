import AVFoundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #652: heard audio around a streamed Margin stays on disk only while that Margin can still use it.
final class HeardSourceWindowFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "heard-windows-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func window(id: String = "ij-001", runsMs: [Int]) -> HeardAudioWindow {
        var startMs = 63_000
        let segments = runsMs.map { durationMs -> HeardAudioWindow.Segment in
            defer { startMs += durationMs + 5_000 }
            return .init(startMediaTimeMs: startMs, samples: [Float](repeating: 0.1, count: durationMs))
        }
        return HeardAudioWindow(
            request: PostResumeAudioSampleRequest(interjectionId: id, sessionId: "session", itemId: "episode",
                                                  anchorMediaTimeMs: 123_000, targetDurationMs: 11_000),
            sampleRate: 1_000, segments: segments, endReason: "complete"
        )
    }

    private func folders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    private func margin(
        status: String = "active",
        context: AnchorContextStatus? = .pending,
        captureKind: InterjectionCaptureKind? = nil,
        mediaTimeMs: Int? = 123_000
    ) -> Interjection {
        Interjection(
            id: "ij-001", itemId: "episode", sessionId: "session", targetType: .item, targetId: "episode",
            createdAt: Date(), roughPercent: 40,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "Before.", anchorAfter: "After.",
                           mediaTimeMs: mediaTimeMs),
            audioPath: "ij-001.m4a", audioStatus: "saved", transcriptionStatus: "pending", transcript: nil,
            cleanedTranscript: nil, displayText: nil, status: status, anchorContextStatus: context, captureKind: captureKind
        )
    }

    func testKeepsQualifyingRunsAsReadableAudioFiles() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let stored = try files.store(window(runsMs: [60_000, 1_500, 30_000]), key: "session::ij-001")

        XCTAssertEqual(stored.map(\.durationMs), [60_000, 30_000], "runs under two seconds aren't worth transcribing")
        XCTAssertEqual(files.segments(for: "session::ij-001"), stored)
        for segment in stored {
            let audio = try AVAudioFile(forReading: segment.url)
            XCTAssertEqual(Int(audio.length), segment.durationMs, "1 sample per ms at the test rate")
        }
        XCTAssertEqual(try folders().count, 1)
    }

    func testAWindowWithNoQualifyingRunLeavesNothingBehind() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        XCTAssertEqual(try files.store(window(runsMs: [1_000]), key: "session::ij-001"), [])
        XCTAssertNil(files.segments(for: "session::ij-001"))
        XCTAssertEqual(try folders(), [])
    }

    func testDiscardDeletesTheFilesAndForgetsTheWindow() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let stored = try files.store(window(runsMs: [60_000]), key: "session::ij-001")
        files.discard("session::ij-001")

        XCTAssertNil(files.segments(for: "session::ij-001"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored[0].url.path))
        XCTAssertEqual(try folders(), [])
    }

    func testANewerWindowForTheSameMarginReplacesTheOlderFiles() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let older = try files.store(window(runsMs: [60_000]), key: "session::ij-001")
        let newer = try files.store(window(runsMs: [30_000]), key: "session::ij-001")

        XCTAssertFalse(FileManager.default.fileExists(atPath: older[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer[0].url.path))
        XCTAssertEqual(try folders().count, 1)
    }

    /// A window handed to a transcription belongs to it: a later window, a discard or a second instance must not
    /// delete the files it is reading.
    func testATakenWindowIsLeftForItsTranscriptionToDelete() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        try files.store(window(runsMs: [60_000]), key: "session::ij-001")
        let taken = try XCTUnwrap(files.take("session::ij-001"))
        XCTAssertNil(files.segments(for: "session::ij-001"))

        files.discard("session::ij-001")
        try files.store(window(runsMs: [30_000]), key: "session::ij-001")
        _ = HeardSourceWindowFiles(rootDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken[0].url.path))

        HeardSourceWindowFiles.delete(taken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: taken[0].url.path))
        XCTAssertEqual(try folders().count, 1, "only the newer, untaken window is left")
    }

    /// #2510: the app writes the audio from a background task and only then keeps it on the main thread, so the
    /// file half must work with no instance and leave the map alone until `adopt`.
    func testTheFilesAreWrittenOffTheMainThreadAndKeptAfterwards() async throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let heard = window(runsMs: [60_000, 1_500, 30_000])
        let directory = root!

        let (written, offMain) = try await Task.detached { () throws -> ([HeardSourceWindowFiles.Segment], Bool) in
            (try HeardSourceWindowFiles.write(heard, in: directory), !Thread.isMainThread)
        }.value

        XCTAssertTrue(offMain)
        XCTAssertEqual(written.map(\.durationMs), [60_000, 30_000])
        XCTAssertNil(files.segments(for: "session::ij-001"), "writing keeps nothing until the caller adopts it")
        XCTAssertEqual(files.adopt(written, key: "session::ij-001"), [])
        XCTAssertEqual(files.segments(for: "session::ij-001"), written)
        XCTAssertEqual(try folders().count, 1)
    }

    func testAdoptingANewerWindowHandsBackTheOlderOneToDelete() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let older = try HeardSourceWindowFiles.write(window(runsMs: [60_000]), in: root)
        let newer = try HeardSourceWindowFiles.write(window(runsMs: [30_000]), in: root)
        XCTAssertEqual(files.adopt(older, key: "session::ij-001"), [])

        let replaced = files.adopt(newer, key: "session::ij-001")

        XCTAssertEqual(replaced, older)
        XCTAssertTrue(FileManager.default.fileExists(atPath: older[0].url.path), "the caller deletes it, off its own thread")
        XCTAssertEqual(files.segments(for: "session::ij-001"), newer)
        HeardSourceWindowFiles.delete(replaced)
        XCTAssertEqual(try folders().count, 1)
    }

    func testAWindowWithNoQualifyingRunIsNotAdoptedAndKeepsTheOlderOne() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let older = try files.store(window(runsMs: [60_000]), key: "session::ij-001")
        let nothing = try HeardSourceWindowFiles.write(window(runsMs: [1_000]), in: root)

        XCTAssertEqual(nothing, [])
        XCTAssertEqual(files.adopt(nothing, key: "session::ij-001"), [])
        XCTAssertEqual(files.segments(for: "session::ij-001"), older)
        XCTAssertEqual(try folders().count, 1, "the empty write leaves no folder behind")
    }

    func testBackgroundDiscardForgetsTheWindowAtOnceAndDeletesTheFilesLater() async throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let stored = try files.store(window(runsMs: [60_000]), key: "session::ij-001")

        files.discardInBackground("session::ij-001")
        XCTAssertNil(files.segments(for: "session::ij-001"))

        for _ in 0..<200 where FileManager.default.fileExists(atPath: stored[0].url.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored[0].url.path))
        XCTAssertEqual(try folders(), [])
    }

    func testOtherMarginsWindowsAreUntouched() throws {
        let files = HeardSourceWindowFiles(rootDirectory: root)
        let kept = try files.store(window(id: "ij-002", runsMs: [60_000]), key: "session::ij-002")
        try files.store(window(runsMs: [60_000]), key: "session::ij-001")
        files.discard("session::ij-001")

        XCTAssertEqual(files.segments(for: "session::ij-002"), kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept[0].url.path))
    }

    /// The map of windows lives in memory, so a folder left by an earlier run can't be used again.
    func testTheFirstInstanceForAFolderClearsFoldersLeftByAnEarlierRun() throws {
        let leftover = root.appending(path: "earlier-run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("pcm".utf8).write(to: leftover.appending(path: "segment-0.caf"))

        let files = HeardSourceWindowFiles(rootDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))

        let live = try files.store(window(runsMs: [60_000]), key: "session::ij-001")
        _ = HeardSourceWindowFiles(rootDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live[0].url.path), "a later instance must not clear live windows")
    }

    func testOnlyAMarginThatCanStillUseTheAudioKeepsIt() {
        XCTAssertTrue(HeardSourceWindowFiles.isStillNeeded(by: margin()))
        XCTAssertTrue(HeardSourceWindowFiles.isStillNeeded(by: margin(context: nil)), "context not tried yet")
        XCTAssertTrue(HeardSourceWindowFiles.isStillNeeded(by: margin(context: .unavailable)), "a retry may still use it")
        XCTAssertTrue(HeardSourceWindowFiles.isStillNeeded(by: margin(captureKind: .audio)))

        XCTAssertFalse(HeardSourceWindowFiles.isStillNeeded(by: nil), "the Margin was removed")
        XCTAssertFalse(HeardSourceWindowFiles.isStillNeeded(by: margin(status: "deleted")))
        XCTAssertFalse(HeardSourceWindowFiles.isStillNeeded(by: margin(context: .ready)), "a ready context isn't replaced")
        XCTAssertFalse(HeardSourceWindowFiles.isStillNeeded(by: margin(captureKind: .written)))
        XCTAssertFalse(HeardSourceWindowFiles.isStillNeeded(by: margin(mediaTimeMs: nil)))
    }
}
