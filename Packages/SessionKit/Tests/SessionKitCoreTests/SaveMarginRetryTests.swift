import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #911: if Save & resume failed once (a database write lock held over a second, a full disk), the
/// recorder had already closed the file and forgotten its path, and the app's Save passes no path. Every
/// later Save threw `invalidCommandForState`, and the audio stayed on disk with no Margin to own it.
/// These tests use a real SQLite file held under a real write lock and a real audio file.
final class SaveMarginRetryTests: XCTestCase {
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
    private var store: SQLiteSessionStore!
    private var databasePath: String { directory.appending(path: "library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "save-margin-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: databasePath)
        try store.saveItem(article)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Follows the contract of the phone's `AVAudioRecorder` adapter (`SystemRecordingClient.finishRecording`):
    /// finishing closes the file and forgets it; asked again with no path it throws, and given a path it
    /// returns that path. Each recording is a real file on disk.
    private final class ClosingRecorder: RecordingClient {
        let directory: URL
        private(set) var recordings: [String] = []
        private var active: String?

        init(directory: URL) { self.directory = directory }

        func beginRecording() throws {
            let relative = "interjections/margin-\(recordings.count + 1).m4a"
            let file = directory.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio for \(relative)".utf8).write(to: file)
            recordings.append(relative)
            active = relative
        }

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

    private struct FailingTranscriber: TranscriptionClient {
        func scheduleTranscription(interjection: Interjection) throws {
            throw SessionKitError.persistenceFailed("transcription_unavailable")
        }
    }

    /// Holds a write transaction on the Library file from a second connection, the way a background writer would.
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

    private func recordingEngine(
        transcriber: TranscriptionClient = DeferredTranscriptionClient()
    ) throws -> (SessionEngine, ClosingRecorder) {
        let recorder = ClosingRecorder(directory: directory)
        let engine = SessionEngine(
            profile: profile, repository: store, audio: NoopAudioPlaybackClient(),
            recorder: recorder, transcriber: transcriber
        )
        _ = try engine.startSession(itemId: article.id)
        return (engine, recorder)
    }

    private func margins(_ engine: SessionEngine) throws -> [Interjection] {
        try store.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id))
    }

    func testSavingAgainAfterAFailedSaveStoresTheOriginalRecording() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()

        let lock = try WriteLock(path: databasePath)
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the write lock outlasts the store's 1 s wait")
        lock.release()

        XCTAssertNoThrow(try engine.finishInterjection(audioRef: nil), "Save again")
        let saved = try margins(engine)
        XCTAssertEqual(saved.count, 1, "exactly one Margin")
        XCTAssertEqual(saved.first?.audioPath, recorder.recordings.first, "with the recording that was made")
        let file = directory.appending(path: try XCTUnwrap(saved.first?.audioPath))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "audio for interjections/margin-1.m4a")
        XCTAssertEqual(recorder.recordings.count, 1, "no second recording was started")
    }

    func testAFailedSaveCanBeRetriedMoreThanOnce() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()

        for _ in 0..<2 {
            let lock = try WriteLock(path: databasePath)
            XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil))
            lock.release()
        }
        _ = try engine.finishInterjection(audioRef: nil)

        XCTAssertEqual(try margins(engine).map(\.audioPath), [recorder.recordings[0]])
    }

    func testCancellingAfterAFailedSaveDoesNotReuseTheOldRecordingForTheNextMargin() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()
        let lock = try WriteLock(path: databasePath)
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil))
        lock.release()

        _ = try engine.cancelInterjection()
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: nil)

        XCTAssertEqual(recorder.recordings.count, 2)
        XCTAssertEqual(try margins(engine).map(\.audioPath), [recorder.recordings[1]], "the new Margin has its own file")
    }

    func testASaveThatFailsAfterTheMarginIsStoredIsNotSavedTwice() throws {
        let (engine, _) = try recordingEngine(transcriber: FailingTranscriber())
        _ = try engine.beginInterjection()

        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the transcriber fails after the Margin is stored")
        XCTAssertEqual(try margins(engine).count, 1)
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the recording is already owned by a Margin")

        XCTAssertEqual(try margins(engine).count, 1, "retrying must not store the same recording as a second Margin")
    }
}
