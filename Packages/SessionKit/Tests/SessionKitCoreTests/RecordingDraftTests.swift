import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #951: a spoken Margin lived only in memory until Save, so the app being killed mid-recording left a file with no
/// record of the source or place it belonged to. The engine now keeps a small note of each recording, and a launch
/// settles the notes. These tests use a real SQLite file, real recording files and real note files, and "kill the
/// app" by dropping the engine and reconciling against what is left on disk.
final class RecordingDraftTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )

    private let article = Item(
        id: "item-article", title: "Article", mediaType: "text",
        text: "First sentence. Second sentence carries the thought on. Third sentence.",
        externalReference: nil, status: "ready"
    )

    private var directory: URL!
    private var journal: RecordingDraftJournal!
    private var store: SQLiteSessionStore!
    private var databasePath: String { directory.appending(path: "library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "recording-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = RecordingDraftJournal(directory: RecordingDraftJournal.standardDirectory(applicationSupport: directory))
        store = try SQLiteSessionStore(path: databasePath)
        try store.saveItem(article)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a real file per recording, named the way the phone's recorder names them, and says so while it records.
    private final class FileRecorder: RecordingClient {
        let directory: URL
        private(set) var recordings: [String] = []
        private var active: String?

        init(directory: URL) { self.directory = directory }

        func beginRecording() throws { try start() }

        private func start() throws {
            let relative = "SpokenMargins/interjections/margin-\(recordings.count + 1).m4a"
            let file = directory.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio for \(relative)".utf8).write(to: file)
            recordings.append(relative)
            active = relative
        }

        func restartCapture() throws {
            if let active { try? FileManager.default.removeItem(at: directory.appending(path: active)) }
            try start()
        }

        func recordingInProgressRef() -> String? { active }

        func finishRecording(audioRef: String?) throws -> String {
            guard let active else {
                if let audioRef { return audioRef }
                throw SessionKitError.invalidCommandForState("finishRecording")
            }
            self.active = nil
            return active
        }

        func cancelRecording() throws {
            if let active { try? FileManager.default.removeItem(at: directory.appending(path: active)) }
            active = nil
        }
    }

    private final class WriteLock {
        private var database: OpaquePointer?
        init(path: String) throws {
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("test_write_lock")
            }
        }
        func release() { XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, nil), SQLITE_OK) }
        deinit { sqlite3_close(database) }
    }

    private func recordingEngine(journal: RecordingDraftJournal? = nil) throws -> (SessionEngine, FileRecorder) {
        let recorder = FileRecorder(directory: directory)
        let engine = SessionEngine(
            profile: profile, repository: store, audio: NoopAudioPlaybackClient(), recorder: recorder
        )
        engine.recordingDraftJournal = journal ?? self.journal
        _ = try engine.startSession(itemId: article.id)
        return (engine, recorder)
    }

    private func reconciler(decodable: @escaping (URL) -> Bool = { _ in true }) -> RecordingDraftReconciler {
        RecordingDraftReconciler(journal: journal, repository: store, applicationSupport: directory, isDecodable: decodable)
    }

    private func reconcile(decodable: @escaping (URL) -> Bool = { _ in true }) throws -> [RecordingDraftReport.Outcome] {
        try reconciler(decodable: decodable).reconcile(savedAudioPaths: { try store.allMarginAudioPaths() }).map(\.outcome)
    }

    private func margins(_ sessionId: String) throws -> [Interjection] {
        try store.loadInterjections(sessionId: sessionId)
    }

    // MARK: - The note

    func testBeginningAMarginNotesItsSourcePlaceAndFileBeforeRecordingIsShown() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()

        let draft = try XCTUnwrap(try journal.load().drafts.first)
        let session = try XCTUnwrap(engine.currentSession)
        XCTAssertEqual(draft.sessionId, session.id)
        XCTAssertEqual(draft.itemId, article.id)
        XCTAssertEqual(draft.anchor, engine.recordingAnchor)
        XCTAssertEqual(draft.audioRef, recorder.recordings.first)
        XCTAssertEqual(draft.state, .recording)
        XCTAssertNil(engine.recordingDraftFailure)
    }

    func testARecorderRestartMovesTheNoteToTheNewFile() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()
        try engine.restartRecordingCapture()

        XCTAssertEqual(recorder.recordings.count, 2)
        XCTAssertEqual(try journal.load().drafts.first?.audioRef, recorder.recordings.last)
    }

    func testANoteThatCannotBeWrittenNeverStopsTheRecording() throws {
        let blocker = directory.appending(path: "not-a-folder")
        try Data().write(to: blocker)
        let (engine, _) = try recordingEngine(journal: RecordingDraftJournal(directory: blocker))

        XCTAssertTrue(try engine.beginInterjection().isRecording)
        XCTAssertNotNil(engine.recordingDraftFailure)
        _ = try engine.finishInterjection(audioRef: nil)
        XCTAssertEqual(try margins(try XCTUnwrap(engine.currentSession).id).count, 1, "Save still works")
    }

    // MARK: - Killed before Save

    func testKilledWhileRecordingAnUnreadableFileIsKeptAndNoMarginIsInvented() throws {
        let (engine, recorder) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        let file = directory.appending(path: try XCTUnwrap(recorder.recordings.first))
        // The app is gone: nothing below asks the engine, only what is on disk.

        XCTAssertEqual(try reconcile(decodable: { _ in false }), [.unreadable(firstTime: true)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the file is never deleted")
        XCTAssertEqual(try margins(sessionId).count, 0, "an unreadable file is not a Margin")
        XCTAssertEqual(try journal.load().drafts.first?.state, .unrecoverable)

        XCTAssertEqual(try reconcile(decodable: { _ in false }), [.unreadable(firstTime: false)], "told once, kept for good")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testKilledWhileRecordingAFileThatStillOpensBecomesOneMarginAtTheSavedPlace() throws {
        let (engine, recorder) = try recordingEngine()
        let session = try XCTUnwrap(engine.currentSession)
        _ = try engine.beginInterjection()
        let anchor = try XCTUnwrap(engine.recordingAnchor)
        let ref = try XCTUnwrap(recorder.recordings.first)

        let outcomes = try reconcile()
        let saved = try margins(session.id)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(outcomes, [.recovered(interjectionId: try XCTUnwrap(saved.first).id)])
        let margin = try XCTUnwrap(saved.first)
        XCTAssertEqual(margin.anchor, anchor, "the place saved when recording began, not a guess")
        XCTAssertEqual(margin.itemId, article.id)
        XCTAssertEqual(margin.audioPath, ref)
        XCTAssertEqual(margin.transcriptionStatus, "pending", "the launch settles this as retryable")
        XCTAssertNil(margin.transcript)
        XCTAssertTrue(try journal.load().drafts.isEmpty)

        XCTAssertEqual(try reconcile(), [], "a second launch recovers nothing more")
        XCTAssertEqual(try margins(session.id).count, 1)
    }

    func testARecoveredMarginIsReportedToTheCallerWithItsSessionAndId() throws {
        let (engine, _) = try recordingEngine()
        let session = try XCTUnwrap(engine.currentSession)
        _ = try engine.beginInterjection()
        var recovered: [String] = []
        _ = try RecordingDraftReconciler(
            journal: journal, repository: store, applicationSupport: directory, isDecodable: { _ in true },
            onRecovered: { recovered.append("\($0)::\($1)") }
        ).reconcile(savedAudioPaths: { try store.allMarginAudioPaths() })
        XCTAssertEqual(recovered, ["\(session.id)::\(try XCTUnwrap(margins(session.id).first).id)"])
    }

    /// The audit of #1570: a reply recovered after a kill came back as a plain Margin, unthreaded and exported
    /// without its link.
    func testKilledWhileRecordingAReplyRecoversTheMarginWithItsReplyLink() throws {
        let (engine, _) = try recordingEngine()
        let session = try XCTUnwrap(engine.currentSession)
        let link = MarginReplyLink(conversationId: "conversation-1", parentPackageDigest: "digest-a", parentPackageScopedId: "margin-1")
        _ = try engine.beginInterjection(request: MarginCaptureRequest(replyTo: link))
        XCTAssertEqual(try journal.load().drafts.first?.replyTo, link, "the note carries the link")

        _ = try reconcile()
        XCTAssertEqual(try margins(session.id).first?.replyTo, link, "the recovered Margin is still a reply")
    }

    func testAMarginThatIsNotAReplyRecoversWithoutALink() throws {
        let (engine, _) = try recordingEngine()
        let session = try XCTUnwrap(engine.currentSession)
        _ = try engine.beginInterjection()
        XCTAssertNil(try journal.load().drafts.first?.replyTo)

        _ = try reconcile()
        XCTAssertNil(try margins(session.id).first?.replyTo)
    }

    func testANoteWrittenBeforeRepliesExistedStillDecodes() throws {
        let (engine, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        let draft = try XCTUnwrap(try journal.load().drafts.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        json.removeValue(forKey: "replyTo")
        XCTAssertNil(json["replyTo"])
        let decoded = try JSONDecoder().decode(RecordingDraft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.replyTo)
        XCTAssertEqual(decoded.id, draft.id)
    }

    func testRecoveryDoesNotTouchTheSession() throws {
        let (engine, _) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        let before = try XCTUnwrap(try store.loadSession(id: sessionId))

        _ = try reconcile()

        let after = try XCTUnwrap(try store.loadSession(id: sessionId))
        XCTAssertEqual(after.position, before.position, "no autoplay and no moved place")
        XCTAssertEqual(after.phase, before.phase)
    }

    // MARK: - Killed around Save

    func testKilledAfterTheRecorderClosedButBeforeTheMarginWasStoredRecoversOne() throws {
        let (engine, recorder) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()

        let lock = try WriteLock(path: databasePath)
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the write lock outlasts the store's wait")
        XCTAssertEqual(try journal.load().drafts.first?.state, .closed)
        XCTAssertEqual(try journal.load().drafts.first?.audioRef, recorder.recordings.first)
        lock.release() // the app dies here, in the real case

        XCTAssertEqual(try margins(sessionId).count, 0)
        let outcomes = try reconcile()
        XCTAssertEqual(try margins(sessionId).count, 1)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try margins(sessionId).first?.audioPath, recorder.recordings.first)
    }

    func testKilledAfterTheMarginWasStoredButBeforeTheNoteWasRemovedAddsNothing() throws {
        let (engine, _) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        let note = try XCTUnwrap(try journal.load().drafts.first)
        _ = try engine.finishInterjection(audioRef: nil)
        XCTAssertTrue(try journal.load().drafts.isEmpty, "a normal Save removes the note")

        try journal.write(note) // as if the kill came before the removal
        XCTAssertEqual(try reconcile(), [.alreadySaved])
        XCTAssertEqual(try margins(sessionId).count, 1, "no duplicate")
        XCTAssertTrue(try journal.load().drafts.isEmpty)
    }

    func testAMarginTheListenerDeletedIsNotBroughtBack() throws {
        let (engine, recorder) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        let note = try XCTUnwrap(try journal.load().drafts.first)
        _ = try engine.finishInterjection(audioRef: nil)
        try journal.write(note)

        // The Margin's row is gone from the live table but still names the recording in quarantine or elsewhere.
        let ref = try XCTUnwrap(recorder.recordings.first)
        let outcomes = try reconciler().reconcile(savedAudioPaths: { [ref] }).map(\.outcome)
        XCTAssertEqual(outcomes, [.alreadySaved])
        XCTAssertEqual(try margins(sessionId).count, 1)
    }

    // MARK: - Cancel and normal Save

    func testACancelledMarginLeavesNoNoteAndIsNeverRecovered() throws {
        let (engine, recorder) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        _ = try engine.cancelInterjection()

        XCTAssertTrue(try journal.load().drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: try XCTUnwrap(recorder.recordings.first)).path))
        XCTAssertEqual(try reconcile(), [])
        XCTAssertEqual(try margins(sessionId).count, 0)
    }

    func testAKillBetweenCancellingTheNoteAndDeletingTheFileStaysCancelled() throws {
        let (engine, recorder) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        let file = directory.appending(path: try XCTUnwrap(recorder.recordings.first))
        _ = try engine.cancelInterjection()
        try Data("left behind".utf8).write(to: file) // the file survived the kill

        XCTAssertEqual(try reconcile(), [], "no note, so nothing is recovered")
        XCTAssertEqual(try margins(sessionId).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "and the file is not deleted either")
    }

    func testANormalSaveLeavesNoNoteAndTheRecordingIntact() throws {
        let (engine, recorder) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: nil)

        XCTAssertTrue(try journal.load().drafts.isEmpty)
        let saved = try XCTUnwrap(try margins(sessionId).first)
        XCTAssertEqual(saved.audioPath, recorder.recordings.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: try XCTUnwrap(saved.audioPath)).path))
        XCTAssertEqual(try reconcile(), [])
    }

    func testARecoveredMarginTakesTheNextNumberInItsSession() throws {
        let (engine, _) = try recordingEngine()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: nil)
        _ = try engine.beginInterjection() // killed here
        _ = try reconcile()

        XCTAssertEqual(try margins(sessionId).map(\.id).sorted(), ["ij-001", "ij-002"])
    }

    func testALaunchWithNoNotesNeverScansTheLibrary() throws {
        var scans = 0
        let reports = try reconciler().reconcile(savedAudioPaths: { scans += 1; return [] })
        XCTAssertEqual(reports, [])
        XCTAssertEqual(scans, 0)
    }

    func testIfTheLibraryScanFailsNothingIsSettled() throws {
        let (engine, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        struct ScanFailed: Error {}
        XCTAssertThrowsError(try reconciler().reconcile(savedAudioPaths: { throw ScanFailed() }))
        XCTAssertEqual(try journal.load().drafts.count, 1, "the note waits for a launch that can check")
        XCTAssertEqual(try margins(try XCTUnwrap(engine.currentSession?.id)).count, 0)
    }

    // MARK: - What stays put

    func testANoteWhoseFileIsGoneIsDroppedAndOneWhoseSourceIsGoneIsKept() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()
        let note = try XCTUnwrap(try journal.load().drafts.first)

        var orphan = note
        orphan.id = "orphan"
        orphan.sessionId = "session-that-was-deleted"
        try journal.write(orphan)
        var vanished = note
        vanished.id = "vanished"
        vanished.audioRef = "SpokenMargins/interjections/gone.m4a"
        try journal.write(vanished)
        var silent = note
        silent.id = "silent"
        silent.audioRef = nil
        try journal.write(silent)

        let outcomes = try reconcile(decodable: { _ in false })
        XCTAssertEqual(Set(outcomes.map { "\($0)" }), Set([
            "\(RecordingDraftReport.Outcome.sourceMissing)",
            "\(RecordingDraftReport.Outcome.fileMissing)",
            "\(RecordingDraftReport.Outcome.noRecording)",
            "\(RecordingDraftReport.Outcome.unreadable(firstTime: true))"
        ]))
        XCTAssertEqual(Set(try journal.load().drafts.map(\.id)), [note.id, "orphan"], "gone files and silent notes are dropped, the rest kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: try XCTUnwrap(recorder.recordings.first)).path))
    }

    func testANoteFileThatDoesNotDecodeIsLeftInPlace() throws {
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: true)
        let strange = journal.directory.appending(path: "from-a-newer-build.json")
        try Data("{\"somethingElse\": true}".utf8).write(to: strange)

        let loaded = try journal.load()
        XCTAssertEqual(loaded.drafts, [])
        XCTAssertEqual(loaded.unreadableFileNames, ["from-a-newer-build.json"])
        XCTAssertEqual(try reconcile(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: strange.path))
    }

    func testTheNoteIsNotInTheDatabase() throws {
        let (engine, _) = try recordingEngine()
        _ = try engine.beginInterjection()
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? Int) ?? 0
        XCTAssertFalse(try journal.load().drafts.isEmpty)
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? Int) ?? 0
        XCTAssertEqual(sizeBefore, sizeAfter, "drafts live in their own folder, so Build 29's database reader never sees them")
    }
}
