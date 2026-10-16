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
    /// returns that path. Each recording is a real file on disk. `honoursPassedPath` makes it return a path it is
    /// given even while recording, as the engine's test doubles do, so a stale path would show up in the Margin.
    private final class ClosingRecorder: RecordingClient {
        let directory: URL
        let honoursPassedPath: Bool
        private(set) var recordings: [String] = []
        private var active: String?

        init(directory: URL, honoursPassedPath: Bool = false) {
            self.directory = directory
            self.honoursPassedPath = honoursPassedPath
        }

        func beginRecording() throws {
            let relative = "interjections/margin-\(recordings.count + 1).m4a"
            let file = directory.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio for \(relative)".utf8).write(to: file)
            recordings.append(relative)
            active = relative
        }

        func finishRecording(audioRef: String?) throws -> String {
            if honoursPassedPath, let audioRef { active = nil; return audioRef }
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
        transcriber: TranscriptionClient = DeferredTranscriptionClient(),
        honoursPassedPath: Bool = false
    ) throws -> (SessionEngine, ClosingRecorder) {
        let recorder = ClosingRecorder(directory: directory, honoursPassedPath: honoursPassedPath)
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
        let (engine, recorder) = try recordingEngine(honoursPassedPath: true)
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

    /// Takes the Library's write lock the moment the Margin's transcription is scheduled, which is after the Margin is
    /// stored and before the session is saved (#1121). The test releases it later.
    private final class LockingTranscriber: TranscriptionClient {
        let path: String
        private(set) var lock: WriteLock?
        private(set) var scheduled: [String] = []
        var locksOnSchedule = true
        init(path: String) { self.path = path }
        func scheduleTranscription(interjection: Interjection) throws {
            scheduled.append(interjection.id)
            if locksOnSchedule, lock == nil { lock = try WriteLock(path: path) }
        }
        func release() { lock?.release(); lock = nil; locksOnSchedule = false }
    }

    /// #1121: the Margin is stored, then a later step (here the session save) fails. Save used to throw on every
    /// retry because the recorder had nothing left to finish, so the recording screen stayed until Cancel.
    func testSavingAgainAfterAStepFailsFollowingTheStoredMarginFinishesTheSameMargin() throws {
        let transcriber = LockingTranscriber(path: databasePath)
        let (engine, recorder) = try recordingEngine(transcriber: transcriber)
        _ = try engine.beginInterjection()

        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the session save waits out the write lock and fails")
        XCTAssertEqual(try margins(engine).count, 1, "the Margin was already stored")
        XCTAssertEqual(engine.snapshot.status, .recording, "the failed Save left the screen on recording")
        transcriber.release()

        XCTAssertNoThrow(try engine.finishInterjection(audioRef: nil), "Save again finishes the rest")
        let saved = try margins(engine)
        XCTAssertEqual(saved.count, 1, "still exactly one Margin")
        XCTAssertEqual(saved.first?.audioPath, recorder.recordings.first)
        XCTAssertNotEqual(engine.snapshot.status, .recording, "the recording screen is gone")
        XCTAssertEqual(engine.snapshot.phase, .itemPlayback, "the source is back")
        XCTAssertEqual(transcriber.scheduled, saved.map(\.id), "transcription was scheduled once, for that Margin")
        XCTAssertEqual(recorder.recordings.count, 1, "no second recording was started")

        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "a finished Margin is not saved again")
        XCTAssertEqual(try margins(engine).count, 1)
    }

    /// Fails the first time it is asked to schedule a transcription, then works.
    private final class FlakyTranscriber: TranscriptionClient {
        private(set) var attempts = 0
        func scheduleTranscription(interjection: Interjection) throws {
            attempts += 1
            if attempts == 1 { throw SessionKitError.persistenceFailed("transcription_unavailable") }
        }
    }

    /// #1713: the failed Save leaves the recording screen up with the Margin already in the Library. Write instead would
    /// have dropped the recording and written a second Margin at the same place.
    func testWriteInsteadAfterAStepFailsFollowingTheStoredMarginIsRefused() throws {
        let transcriber = FlakyTranscriber()
        let (engine, recorder) = try recordingEngine(transcriber: transcriber)
        _ = try engine.beginInterjection()
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "scheduling the transcription fails after the Margin is stored")
        XCTAssertEqual(try margins(engine).count, 1, "the Margin was already stored")

        XCTAssertThrowsError(try engine.switchRecordingToWrittenInterjection(), "the Margin is stored; finish it with Save")
        XCTAssertEqual(try margins(engine).count, 1, "no second Margin")
        XCTAssertEqual(engine.snapshot.status, .recording, "the screen is still on recording")

        XCTAssertNoThrow(try engine.finishInterjection(audioRef: nil), "Save finishes the stored Margin")
        let saved = try margins(engine)
        XCTAssertEqual(saved.map(\.audioPath), [recorder.recordings[0]], "one spoken Margin, with the recording that was made")
        XCTAssertFalse(saved.contains { $0.captureKind == .written }, "and nothing written beside it")
    }

    /// #1713: Cancel would keep the stored Margin and tell the listener it was not saved.
    func testCancelAfterAStepFailsFollowingTheStoredMarginIsRefused() throws {
        let transcriber = LockingTranscriber(path: databasePath)
        let (engine, recorder) = try recordingEngine(transcriber: transcriber)
        _ = try engine.beginInterjection()
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil))
        transcriber.release()

        XCTAssertThrowsError(try engine.cancelInterjection(), "the Margin is stored; finish it with Save")
        XCTAssertEqual(try margins(engine).count, 1)
        XCTAssertEqual(engine.snapshot.status, .recording)

        XCTAssertNoThrow(try engine.finishInterjection(audioRef: nil))
        XCTAssertEqual(try margins(engine).map(\.audioPath), [recorder.recordings[0]])
    }

    /// #1713: a Save that closed the recording and failed before storing it keeps the recording for the next Save.
    func testWriteInsteadAfterASaveThatClosedTheRecordingButStoredNothingIsRefused() throws {
        let (engine, recorder) = try recordingEngine()
        _ = try engine.beginInterjection()
        let lock = try WriteLock(path: databasePath)
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the write lock outlasts the store's 1 s wait")
        lock.release()

        XCTAssertThrowsError(try engine.switchRecordingToWrittenInterjection(), "the closed recording is still to be saved")
        XCTAssertEqual(engine.snapshot.status, .recording)

        XCTAssertNoThrow(try engine.finishInterjection(audioRef: nil))
        XCTAssertEqual(try margins(engine).map(\.audioPath), [recorder.recordings[0]], "the recording survived the refused switch")
    }

    /// Cancel before any Save, and after a Save that stored nothing, still work (#911).
    func testWriteInsteadBeforeAnySaveStillSwitches() throws {
        let (engine, _) = try recordingEngine()
        _ = try engine.beginInterjection()

        let capture = try engine.switchRecordingToWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Written.")

        XCTAssertEqual(try margins(engine).map { $0.captureKind == .written }, [true])
    }

    /// The next Margin after one that needed a retry starts clean.
    func testAMarginRecordedAfterARetriedSaveIsFinishedOnItsOwn() throws {
        let transcriber = LockingTranscriber(path: databasePath)
        let (engine, recorder) = try recordingEngine(transcriber: transcriber)
        _ = try engine.beginInterjection()
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil))
        transcriber.release()
        _ = try engine.finishInterjection(audioRef: nil)

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: nil)

        XCTAssertEqual(try margins(engine).map(\.audioPath), recorder.recordings, "two Margins, each with its own file")
        XCTAssertEqual(transcriber.scheduled.count, 2)
    }

    /// Plays a podcast from the position it is told, the way a real player does after a seek.
    private final class PodcastAudio: AudioPlaybackClient {
        var mediaTimeMs: Int? = 60_000
        var plays: [Int] = []
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
        func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
            self.mediaTimeMs = mediaTimeMs
            plays.append(mediaTimeMs)
        }
        func currentPlaybackPosition() -> PlaybackPosition? {
            mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: 3_600_000, anchorConfidence: .mediaTime) }
        }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func pause() throws {}
    }

    /// A podcast rejoins 3 s before where the Margin was made. A retry must not step back again.
    func testARetriedSaveStepsAPodcastBackOnlyOnce() throws {
        let episode = Item(
            id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 3_600_000)
        )
        try store.saveItem(episode)
        let audio = PodcastAudio()
        let transcriber = LockingTranscriber(path: databasePath)
        let mediaProfile = RuntimeCapabilityProfile(
            id: profile.id, displayName: profile.displayName,
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"],
                           "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]]
        )
        let engine = SessionEngine(
            profile: mediaProfile, repository: store, audio: audio,
            recorder: ClosingRecorder(directory: directory), transcriber: transcriber
        )
        _ = try engine.startSession(itemId: episode.id)
        audio.mediaTimeMs = 60_000
        _ = try engine.beginInterjection()

        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil))
        transcriber.release()
        XCTAssertNoThrow(try engine.finishInterjection(audioRef: nil))

        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 57_000, "3 s back from where the Margin was made, once")
        XCTAssertEqual(audio.plays.last, 57_000)
        XCTAssertEqual(try margins(engine).count, 1)
    }

    func testASaveThatFailsAfterTheMarginIsStoredIsNotSavedTwice() throws {
        let (engine, _) = try recordingEngine(transcriber: FailingTranscriber())
        _ = try engine.beginInterjection()

        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the transcriber fails after the Margin is stored")
        XCTAssertEqual(try margins(engine).count, 1)
        XCTAssertThrowsError(try engine.finishInterjection(audioRef: nil), "the transcriber still fails, and the recording is already owned by a Margin")

        XCTAssertEqual(try margins(engine).count, 1, "retrying must not store the same recording as a second Margin")
    }
}
