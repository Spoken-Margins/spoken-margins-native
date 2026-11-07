import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #3491: the recording screen a live session presents is driven by the phone's capture, and Cancel throws the
/// recording away instead of filing it.
final class LiveSessionRecordingScreenAppTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func filedItems(in root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    @MainActor
    func testStartingStateIsSetOnStartAndClearedOnStop() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        XCTAssertNil(capture.recordingStartedAt)
        XCTAssertFalse(capture.isStarting)

        capture.start(sessionId: "s")
        XCTAssertNotNil(capture.recordingStartedAt)
        XCTAssertTrue(capture.isStarting, "the screen says it is waiting until the recorder has the microphone")

        let stopped = capture.stopAndFile()
        await stopped?.value
        XCTAssertNil(capture.recordingStartedAt)
        XCTAssertFalse(capture.isStarting)
    }

    @MainActor
    func testCancelClearsTheRecordingAndFilesNothing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        capture.start(sessionId: "s")
        capture.cancel(sessionId: "s")
        XCTAssertNil(capture.sessionId)
        XCTAssertNil(capture.recordingStartedAt)
        XCTAssertFalse(capture.isStarting)
        try await settle()
        XCTAssertEqual(filedItems(in: root), [], "a discarded recording is never filed")
    }

    @MainActor
    func testTheAdapterCancelDiscardsAndTheScreenShowsTheStartingState() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        capture.start(sessionId: "s")
        let view = LiveSessionRecordingView(
            capture: capture, sessionId: "s", anchorTitle: "Budget meeting", anchorSubtitle: { "12:30" }, onWriteInstead: {}
        )
        XCTAssertEqual(view.state.phase, .starting)
        XCTAssertEqual(view.state.anchorTitle, "Budget meeting")
        XCTAssertNil(view.state.reply)
        XCTAssertNil(view.state.justHeard)
        XCTAssertFalse(view.state.canRetry)

        view.actions.cancel()
        XCTAssertNil(capture.sessionId)
        try await settle()
        XCTAssertEqual(filedItems(in: root), [], "Cancel calls cancel, not stopAndFile")
    }

    @MainActor
    func testWriteInsteadDiscardsTheRecordingThenAsksToWrite() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        capture.start(sessionId: "s")
        var wrote = 0
        let view = LiveSessionRecordingView(
            capture: capture, sessionId: "s", anchorTitle: "t", anchorSubtitle: { "" }, onWriteInstead: { wrote += 1 }
        )
        view.actions.writeInstead(true)
        XCTAssertNil(capture.sessionId)
        XCTAssertEqual(wrote, 1)
        try await settle()
        XCTAssertEqual(filedItems(in: root), [])
    }
}
