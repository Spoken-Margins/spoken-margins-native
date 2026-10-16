import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1669: a listener who is recording a spoken Margin can switch to writing it. The recording is dropped (its file
/// and its note), and the written Margin opens at the place the recording was locked to, answering the same shared
/// Margin. These tests use a real SQLite file, real recording files and the real draft journal.
final class SwitchRecordingToWrittenMarginTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )

    private let text = "First sentence. Second sentence carries the thought on. Third sentence."

    private var article: Item {
        Item(id: "item-article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    private let parent = MarginPacketIdentity(packageDigest: String(repeating: "b", count: 64), packageScopedId: "b-1")
    private var link: MarginReplyLink { .replying(to: parent, parentConversationId: nil) }

    private var directory: URL!
    private var journal: RecordingDraftJournal!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "switch-to-written-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = RecordingDraftJournal(directory: RecordingDraftJournal.standardDirectory(applicationSupport: directory))
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        try store.saveItem(article)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Speech that reports a position the test moves, and counts every start.
    private final class Player: AudioPlaybackClient {
        var charOffset = 20
        var playCount = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playCount += 1 }
        func play(targetId: String, from charOffset: Int) throws { playCount += 1 }
        func currentCharOffset() -> Int? { charOffset }
        func pause() throws {}
    }

    /// Writes a real file per recording and removes it on cancel, as the phone's recorder does.
    private final class FileRecorder: RecordingClient {
        let directory: URL
        var cancelFails = false
        private(set) var recordings: [String] = []
        private(set) var cancelled = 0
        private var active: String?

        init(directory: URL) { self.directory = directory }

        func beginRecording() throws {
            let relative = "SpokenMargins/interjections/margin-\(recordings.count + 1).m4a"
            let file = directory.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: file)
            recordings.append(relative)
            active = relative
        }

        func recordingInProgressRef() -> String? { active }

        func finishRecording(audioRef: String?) throws -> String {
            guard let active else { throw SessionKitError.invalidCommandForState("finishRecording") }
            self.active = nil
            return active
        }

        func cancelRecording() throws {
            if cancelFails { throw SessionKitError.invalidCommandForState("cancelRecording") }
            if let active { try? FileManager.default.removeItem(at: directory.appending(path: active)) }
            active = nil
            cancelled += 1
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appending(path: relative).path)
        }
    }

    private func recordingEngine(
        repository: SessionRepository? = nil, session: Session? = nil
    ) throws -> (SessionEngine, Player, FileRecorder) {
        let player = Player()
        let recorder = FileRecorder(directory: directory)
        let engine = SessionEngine(profile: profile, repository: repository ?? store, audio: player, recorder: recorder)
        engine.recordingDraftJournal = journal
        if let session {
            _ = try engine.inspectSession(sessionId: session.id)
        } else {
            _ = try engine.startSession(itemId: article.id)
        }
        return (engine, player, recorder)
    }

    private func margins(_ engine: SessionEngine) throws -> [Interjection] {
        try store.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id))
    }

    func testTheWrittenMarginIsAnchoredWhereTheRecordingWasLocked() throws {
        let (engine, player, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        player.charOffset = 55 // the player drifts on while the listener talks; the anchor stays where the Margin began

        let capture = try engine.switchRecordingToWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Better said in writing.")

        // The same place, recorded the ordinary way by a second engine over a second library.
        let otherStore = try SQLiteSessionStore(path: directory.appending(path: "other.sqlite").path)
        try otherStore.saveItem(article)
        let otherPlayer = Player()
        let other = SessionEngine(profile: profile, repository: otherStore, audio: otherPlayer, recorder: FileRecorder(directory: directory))
        _ = try other.startSession(itemId: article.id)
        _ = try other.beginInterjection()
        _ = try other.finishInterjection(audioRef: "interjections/reference.m4a")
        let reference = try XCTUnwrap(otherStore.loadInterjections(sessionId: try XCTUnwrap(other.currentSession?.id)).first)

        let written = try XCTUnwrap(margins(engine).first)
        XCTAssertEqual(written.anchor, reference.anchor)
        XCTAssertEqual(written.roughPercent, reference.roughPercent)
        XCTAssertEqual(written.captureKind, .written)
        XCTAssertEqual(written.displayText, "Better said in writing.")
        XCTAssertEqual(written.targetType, reference.targetType)
        XCTAssertEqual(written.targetId, reference.targetId)
    }

    func testTheRecordingIsDroppedAndOnlyTheWrittenMarginIsKept() throws {
        let (engine, _, recorder) = try recordingEngine()
        let recording = try engine.beginInterjection()
        XCTAssertTrue(recording.isRecording)
        let file = try XCTUnwrap(recorder.recordings.first)
        XCTAssertTrue(recorder.exists(file))
        XCTAssertEqual(try journal.load().drafts.count, 1, "the recording has its note")

        let capture = try engine.switchRecordingToWrittenInterjection()

        XCTAssertFalse(engine.snapshot.isRecording)
        XCTAssertEqual(engine.snapshot.status, .paused)
        XCTAssertFalse(recorder.exists(file), "the recording's file is gone")
        XCTAssertEqual(try journal.load().drafts.count, 0, "and so is its note")
        XCTAssertTrue(try margins(engine).isEmpty, "nothing is saved until the listener saves the writing")

        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Written.")
        let kept = try margins(engine)
        XCTAssertEqual(kept.map(\.captureKind), [.written])
        XCTAssertNil(kept.first?.audioPath)
    }

    func testAReplyStaysAReply() throws {
        let (engine, _, _) = try recordingEngine()
        _ = try engine.beginInterjection(request: MarginCaptureRequest().replying(to: link))

        let capture = try engine.switchRecordingToWrittenInterjection()
        XCTAssertEqual(capture.replyTo, link)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "I disagree.")

        XCTAssertEqual(try margins(engine).first?.replyTo, link)
    }

    func testAnOrdinaryMarginDoesNotBecomeAReply() throws {
        let (engine, _, _) = try recordingEngine()
        _ = try engine.beginInterjection()

        let capture = try engine.switchRecordingToWrittenInterjection()

        XCTAssertNil(capture.replyTo)
    }

    func testSavingTheWritingPlaysTheSourceOnFromTheLockedPlace() throws {
        let (engine, player, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        let playsBefore = player.playCount // the session's own start
        let capture = try engine.switchRecordingToWrittenInterjection()
        XCTAssertTrue(capture.wasPlaying, "Save & resume, as for the spoken Margin it replaces")
        XCTAssertEqual(player.playCount, playsBefore, "nothing plays while the listener writes")

        let saved = try engine.saveWrittenInterjection(captureId: capture.id, text: "Back to it.")

        XCTAssertEqual(player.playCount, playsBefore + 1)
        XCTAssertTrue(saved.status.isPlaybackActive)
        XCTAssertEqual(saved.phase, .itemPlayback)
    }

    func testASourceThatSomethingElsePlaysOnForStaysPausedAfterTheWriting() throws {
        let (engine, player, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        let playsBefore = player.playCount

        // A Margin's voice the recording held plays on instead, as when a spoken Margin is cancelled over it.
        let capture = try engine.switchRecordingToWrittenInterjection(resumesSource: false)
        XCTAssertFalse(capture.wasPlaying)
        let saved = try engine.saveWrittenInterjection(captureId: capture.id, text: "Over the voice.")

        XCTAssertEqual(player.playCount, playsBefore)
        XCTAssertFalse(saved.status.isPlaybackActive)
        XCTAssertEqual(try margins(engine).count, 1)
    }

    func testCancellingTheWritingPlaysTheSourceOnAndSavesNothing() throws {
        let (engine, player, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        let playsBefore = player.playCount
        let capture = try engine.switchRecordingToWrittenInterjection()

        let cancelled = try engine.cancelWrittenInterjection(captureId: capture.id)

        XCTAssertEqual(player.playCount, playsBefore + 1)
        XCTAssertTrue(cancelled.status.isPlaybackActive)
        XCTAssertTrue(try margins(engine).isEmpty)
    }

    func testAnotherMarginCanBeRecordedAfterTheSwitch() throws {
        let (engine, _, _) = try recordingEngine()
        _ = try engine.beginInterjection(request: MarginCaptureRequest().replying(to: link))
        let capture = try engine.switchRecordingToWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Written.")

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/after.m4a")

        let kept = try margins(engine)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first { $0.captureKind == .written }?.replyTo, link)
        XCTAssertNil(kept.first { $0.captureKind != .written }?.replyTo, "the link goes with the Margin it began, not the next one")
    }

    func testNothingToSwitchWhenNothingIsRecording() throws {
        let (engine, _, recorder) = try recordingEngine()

        XCTAssertThrowsError(try engine.switchRecordingToWrittenInterjection())

        XCTAssertEqual(recorder.cancelled, 0)
        XCTAssertFalse(engine.snapshot.isRecording)
    }

    func testARecorderThatWontCancelLeavesTheRecordingRunning() throws {
        let (engine, _, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()
        recorder.cancelFails = true

        XCTAssertThrowsError(try engine.switchRecordingToWrittenInterjection())

        XCTAssertTrue(engine.snapshot.isRecording, "still recording, so the screen still says so")
        recorder.cancelFails = false
        _ = try engine.finishInterjection(audioRef: nil)
        XCTAssertEqual(try margins(engine).map { $0.captureKind == .written }, [false], "the recording can still be saved")
    }

    func testAFinishedSourceStaysFinished() throws {
        let finished = Session(
            id: "session-finished", itemId: article.id, status: "finished", phase: .finished,
            currentTargetType: .itemTextTTS, currentTargetId: article.id,
            position: Position(charOffset: text.count, chapterId: nil), completionPercent: 100, playbackRate: 1
        )
        try store.saveSession(finished)
        let (engine, player, _) = try recordingEngine(session: finished)
        _ = try engine.beginInterjection()
        let playsBefore = player.playCount

        let capture = try engine.switchRecordingToWrittenInterjection()
        XCTAssertFalse(capture.wasPlaying, "there is nothing left to play on")
        XCTAssertEqual(engine.snapshot.phase, .finished)
        let saved = try engine.saveWrittenInterjection(captureId: capture.id, text: "A recap.")

        XCTAssertEqual(player.playCount, playsBefore)
        XCTAssertFalse(saved.status.isPlaybackActive)
        XCTAssertEqual(saved.phase, .finished)
        let margin = try XCTUnwrap(margins(engine).first)
        XCTAssertEqual(margin.anchor.startChar, text.count, "the recap is anchored at the end, not at the stopped player's 20")
        XCTAssertEqual(margin.roughPercent, 100)
    }
}
