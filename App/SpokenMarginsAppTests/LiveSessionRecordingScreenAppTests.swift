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

        // Stop clears the screen's state at once. The returned task is not awaited: it waits on the real microphone
        // permission and recorder, which a test simulator can hold for minutes (lane run 42526217263 hung here).
        XCTAssertNotNil(capture.stopAndFile())
        XCTAssertNil(capture.recordingStartedAt)
        XCTAssertFalse(capture.isStarting)
        try await settle()
        XCTAssertNil(capture.recordingStartedAt, "a start finishing after the stop does not bring the clock back")
        XCTAssertFalse(capture.isStarting)
    }

    /// A capture recording for session "s", which is saved first so a recording that is filed has somewhere to go. The
    /// stand-in recorder needs no microphone, so the recording starts at once and Finish files it (#4311).
    @MainActor
    private func recording(in root: URL) async throws -> (LiveSessionSpokenCapture, LiveSessionFileWorker, StandInMarginRecorder) {
        let files = LiveSessionFileWorker(root: root)
        let saved = try await files.save(LiveSession(id: "s", title: "Budget meeting", startedAt: Date().addingTimeInterval(-60)), generation: 1)
        XCTAssertTrue(saved)
        let recorder = StandInMarginRecorder()
        let capture = LiveSessionSpokenCapture(files: files, recorder: recorder, transcribe: { _ in nil })
        capture.start(sessionId: "s")
        return (capture, files, recorder)
    }

    /// Waits until the recorder was told to stop or to cancel, and says how many times each.
    private func ending(of recorder: StandInMarginRecorder) async throws -> (stops: Int, cancels: Int) {
        try await pollUntil(timeout: .seconds(10)) { await recorder.stops + recorder.cancels > 0 }
        return (await recorder.stops, await recorder.cancels)
    }

    /// The control for the Cancel tests below: the same set-up does file a recording when it is finished, so their
    /// "no Margins" is not the store failing to show one.
    @MainActor
    func testFinishFilesTheRecordingIntoItsSession() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (capture, files, recorder) = try await recording(in: root)
        let view = LiveSessionRecordingView(capture: capture, sessionId: "s", anchorTitle: "t", anchorSubtitle: { "" }, onWriteInstead: { _ in })
        view.actions.finish()
        try await pollUntil(timeout: .seconds(10)) { await files.session(id: "s")?.margins.isEmpty == false }
        let margins = await files.session(id: "s")?.margins ?? []
        XCTAssertEqual(margins.map(\.spokenOn), ["phone"], "Finish files the recording into the session")
        let ended = (stops: await recorder.stops, cancels: await recorder.cancels)
        XCTAssertEqual(ended.stops, 1)
        XCTAssertEqual(ended.cancels, 0)
    }

    @MainActor
    func testCancelClearsTheRecordingAndFilesNothing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (capture, files, recorder) = try await recording(in: root)
        capture.cancel(sessionId: "s")
        XCTAssertNil(capture.sessionId)
        XCTAssertNil(capture.recordingStartedAt)
        XCTAssertFalse(capture.isStarting)
        let ended = try await ending(of: recorder)
        XCTAssertEqual(ended.cancels, 1, "the recorder threw the recording away")
        XCTAssertEqual(ended.stops, 0, "a discarded recording is never stopped and filed")
        let margins = await files.session(id: "s")?.margins
        XCTAssertEqual(margins?.count, 0, "a discarded recording is never filed")
    }

    @MainActor
    func testTheAdapterCancelDiscardsAndTheScreenShowsTheStartingState() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (capture, files, recorder) = try await recording(in: root)
        var cancelled = 0
        let view = LiveSessionRecordingView(
            capture: capture, sessionId: "s", anchorTitle: "Budget meeting", anchorSubtitle: { "12:30" }, onWriteInstead: { _ in },
            onCancelled: { cancelled += 1 }
        )
        XCTAssertEqual(view.state.phase, .starting)
        XCTAssertEqual(view.state.anchorTitle, "Budget meeting")
        XCTAssertNil(view.state.reply)
        XCTAssertNil(view.state.justHeard)
        XCTAssertFalse(view.state.canRetry)

        view.actions.cancel()
        XCTAssertNil(capture.sessionId)
        XCTAssertEqual(cancelled, 1)
        let ended = try await ending(of: recorder)
        XCTAssertEqual(ended.cancels, 1, "Cancel calls cancel, not stopAndFile")
        XCTAssertEqual(ended.stops, 0, "Cancel calls cancel, not stopAndFile")
        let margins = await files.session(id: "s")?.margins
        XCTAssertEqual(margins?.count, 0, "Cancel files nothing")
    }

    @MainActor
    func testWriteInsteadDiscardsTheRecordingThenAsksToWrite() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (capture, files, recorder) = try await recording(in: root)
        var wrote = 0
        let view = LiveSessionRecordingView(
            capture: capture, sessionId: "s", anchorTitle: "t", anchorSubtitle: { "" }, onWriteInstead: { _ in wrote += 1 }
        )
        view.actions.writeInstead(true)
        XCTAssertNil(capture.sessionId)
        XCTAssertEqual(wrote, 1)
        let ended = try await ending(of: recorder)
        XCTAssertEqual(ended.cancels, 1, "writing instead throws the recording away")
        XCTAssertEqual(ended.stops, 0, "writing instead never files the recording as well")
        let margins = await files.session(id: "s")?.margins
        XCTAssertEqual(margins?.count, 0)
    }

    /// The audit on 17f2ffa: cancel clears the recording's start, so writing instead used the moment of the change
    /// of mind and filed the Margin a recording's length too late.
    @MainActor
    func testWriteInsteadHandsOverWhenTheRecordingBeganNotWhenTheListenerChangedTheirMind() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        capture.start(sessionId: "s")
        let began = try XCTUnwrap(capture.recordingStartedAt)
        var handedOver: Date??
        let view = LiveSessionRecordingView(
            capture: capture, sessionId: "s", anchorTitle: "t", anchorSubtitle: { "" }, onWriteInstead: { handedOver = .some($0) }
        )
        view.actions.writeInstead(true)
        XCTAssertNil(capture.recordingStartedAt, "cancel clears it, which is why it is read first")
        XCTAssertEqual(handedOver, .some(.some(began)))
    }
}

/// A recorder that needs no microphone (#4311): it starts at once, `stop` hands back a recording, and it counts how each
/// recording ended, so a test can tell a recording filed from one thrown away.
actor StandInMarginRecorder: LiveSessionMarginRecorder {
    private(set) var stops = 0
    private(set) var cancels = 0
    private var startedAt: Date?

    func checkCanRecord() async throws {}

    func start() async throws {
        startedAt = startedAt ?? Date()
    }

    func stop() async throws -> LiveSessionPhoneRecorder.Recording? {
        stops += 1
        guard let startedAt else { return nil }
        self.startedAt = nil
        return LiveSessionPhoneRecorder.Recording(audioPath: "SpokenMargins/interjections/stand-in.m4a", startedAt: startedAt, durationMs: 1_000)
    }

    func cancel() async {
        cancels += 1
        startedAt = nil
    }

    func isCapturing() async -> Bool { startedAt != nil }
}
