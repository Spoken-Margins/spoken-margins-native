import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #942: "Transcribing…" must mean a worker exists. These run against real SQLite files, reopened the way a
/// relaunch reopens them, because the bug lived in what was stored, not in how one screen drew it.
final class OrphanedTranscriptionTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    // MARK: Deleting a transcript

    func testADeletedTranscriptStaysDeletedAndOffersRetryAfterReopeningTheDatabase() throws {
        let path = makePath()
        let (store, engine) = try makeEngine(path: path)
        try store.saveInterjection(margin(id: "m1", status: "transcribed", words: "Spoken"))

        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")

        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.settleOrphanedTranscriptions(), 0, "nothing is pending, so a relaunch has nothing to settle")
        let stored = try XCTUnwrap(try reopened.loadInterjections(sessionId: "session-A").first)
        XCTAssertNil(stored.transcript, "deleting the words must not bring them back")
        XCTAssertEqual(stored.transcriptionStatus, "failed")
        XCTAssertNotNil(stored.audioPath, "the voice stays playable and can be transcribed again")
        let words = TranscriptionFailureWording.marginStatus(transcriptionStatus: stored.transcriptionStatus, speechRecognitionOff: false)
        XCTAssertEqual(words, "Transcription needs retry")
        XCTAssertNotEqual(words, TranscriptionFailureWording.marginStatus(transcriptionStatus: "pending", speechRecognitionOff: false))
    }

    func testRetryAfterADeleteCompletesFromTheFailedState() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin(id: "m1", status: "transcribed", words: "Spoken"))
        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")

        _ = try engine.transcriptionRetryFailed(interjectionId: "m1", sessionId: "session-A", error: "boom")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.transcriptionStatus, "failed", "a failed retry stays failed")

        engine.transcriptionRequested(interjectionId: "m1", sessionId: "session-A") // the app's Retry
        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Again")
        let stored = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertEqual(stored.transcriptionStatus, "transcribed")
        XCTAssertEqual(stored.transcript, "Again")
    }

    // MARK: Work that finishes after the listener deleted the words

    func testWorkThatFinishesAfterADeleteDoesNotBringTheWordsBack() throws {
        let (store, engine) = try makeEngine(path: makePath())
        var aligned = margin(id: "m1", status: "failed", words: "Old words")
        aligned.alignedTranscript = AlignedInterjectionTranscript(text: "Old words", segments: [])
        try store.saveInterjection(aligned)

        // The listener deletes the words while a Retry is running.
        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")
        let afterDelete = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertNil(afterDelete.alignedTranscript, "the aligned copy holds the same words")

        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Late words")
        _ = try engine.transcriptionCompleted(
            interjectionId: "m1", sessionId: "session-A",
            alignedTranscript: AlignedInterjectionTranscript(text: "Late aligned", segments: [])
        )
        _ = try engine.cleanupCompleted(interjectionId: "m1", sessionId: "session-A", cleanedTranscript: "Late cleaned")

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first, afterDelete,
                       "nothing the finished work returns reaches the row, so nothing reaches exports or notes")
    }

    func testAFreshRetryAfterADeleteMayReplaceTheWordsAndDuplicateRequestsAreHarmless() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin(id: "m1", status: "transcribed", words: "Old"))
        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")

        engine.transcriptionRequested(interjectionId: "m1", sessionId: "session-A")
        engine.transcriptionRequested(interjectionId: "m1", sessionId: "session-A")
        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "New")

        let stored = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertEqual(stored.transcript, "New")
        XCTAssertEqual(stored.transcriptionStatus, "transcribed")
    }

    func testADeleteInOneSessionDoesNotBlockTheSameIdMarginInAnother() throws {
        let (store, engine) = try makeEngine(path: makePath())
        var other = margin(id: "same-id", status: "pending", words: nil)
        other.sessionId = "session-B"
        try store.saveInterjection(margin(id: "same-id", status: "transcribed", words: "A"))
        try store.saveInterjection(other)
        _ = try engine.deleteRepresentation(interjectionId: "same-id", sessionId: "session-A", representation: "transcript")

        _ = try engine.transcriptionCompleted(interjectionId: "same-id", sessionId: "session-B", transcript: "B words")

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-B").first?.transcript, "B words")
        XCTAssertNil(try store.loadInterjections(sessionId: "session-A").first?.transcript)
    }

    func testAMarginDeletedWhileWorkFinishesStaysDeleted() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin(id: "m1", status: "pending", words: nil))
        _ = try engine.deleteInterjection(interjectionId: "m1", sessionId: "session-A")

        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Late")

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.status, "deleted")
        XCTAssertEqual(try store.settleOrphanedTranscriptions(), 0)
    }

    // MARK: Launch recovery

    func testALaunchSettlesVoiceMarginsLeftPendingByAnEarlierRun() throws {
        let path = makePath()
        let (store, _) = try makeEngine(path: path)
        try store.saveInterjection(margin(id: "orphan", status: "pending", words: nil))

        let relaunched = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try relaunched.settleOrphanedTranscriptions(), 1)

        let stored = try XCTUnwrap(try relaunched.loadInterjections(sessionId: "session-A").first)
        XCTAssertEqual(stored.transcriptionStatus, "failed")
        var expected = margin(id: "orphan", status: "pending", words: nil)
        expected.transcriptionStatus = "failed"
        XCTAssertEqual(stored, expected, "only the status changes: recording, anchor and everything else stay")
        XCTAssertEqual(try relaunched.settleOrphanedTranscriptions(), 0, "a second launch finds nothing left to settle")
    }

    func testALaunchLeavesEveryOtherMarginAlone() throws {
        let path = makePath()
        let (store, _) = try makeEngine(path: path)
        var written = margin(id: "written", status: "pending", words: "Typed")
        written.captureKind = .written
        written.audioPath = nil
        var noRecording = margin(id: "no-audio", status: "pending", words: nil)
        noRecording.audioPath = nil
        var deleted = margin(id: "deleted", status: "pending", words: nil)
        deleted.status = "deleted"
        let rows = [
            margin(id: "done", status: "transcribed", words: "Spoken"),
            margin(id: "complete", status: "complete", words: "Spoken"),
            margin(id: "failed", status: "failed", words: nil),
            written, noRecording, deleted,
            // The word "pending" in the listener's own words is not a status.
            margin(id: "says-pending", status: "transcribed", words: "pending"),
        ]
        for row in rows { try store.saveInterjection(row) }

        XCTAssertEqual(try store.settleOrphanedTranscriptions(), 0)

        let stored = Dictionary(uniqueKeysWithValues: try store.loadInterjections(sessionId: "session-A").map { ($0.id, $0) })
        for row in rows { XCTAssertEqual(stored[row.id], row, row.id) }
    }

    func testALaunchSettlesPendingMarginsInEverySession() throws {
        let path = makePath()
        let (store, _) = try makeEngine(path: path)
        var other = margin(id: "orphan-b", status: "pending", words: nil)
        other.sessionId = "session-B"
        try store.saveInterjection(margin(id: "orphan-a", status: "pending", words: nil))
        try store.saveInterjection(other)

        XCTAssertEqual(try store.settleOrphanedTranscriptions(), 2)

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.transcriptionStatus, "failed")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-B").first?.transcriptionStatus, "failed")
    }

    // MARK: A retry that fails

    func testAFailedRetryOfAMarginThatWasNeverTranscribedDoesNotLeaveItPending() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin(id: "m1", status: "pending", words: nil))

        _ = try engine.transcriptionRetryFailed(interjectionId: "m1", sessionId: "session-A", error: "speech_recognition_not_authorized")

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.transcriptionStatus, "failed")
    }

    func testAFailedRetryKeepsTheWordsAndStatusOfAMarginThatAlreadyHasThem() throws {
        let (store, engine) = try makeEngine(path: makePath())
        let done = margin(id: "m1", status: "transcribed", words: "Spoken")
        try store.saveInterjection(done)

        _ = try engine.transcriptionRetryFailed(interjectionId: "m1", sessionId: "session-A", error: "boom")

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first, done)
    }

    func testARetryFailureForAMarginInAnotherSessionLeavesThisSessionsSameIdMarginAlone() throws {
        let (store, engine) = try makeEngine(path: makePath())
        var other = margin(id: "same-id", status: "pending", words: nil)
        other.sessionId = "session-B"
        try store.saveInterjection(margin(id: "same-id", status: "pending", words: nil))
        try store.saveInterjection(other)

        _ = try engine.transcriptionRetryFailed(interjectionId: "same-id", sessionId: "session-B", error: "boom")

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.transcriptionStatus, "pending")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-B").first?.transcriptionStatus, "failed")
    }

    // MARK: The policy on its own

    func testOnlyAVoiceMarginWithARecordingAndPendingStatusIsAnOrphan() {
        XCTAssertEqual(OrphanedTranscription.settled(margin(id: "a", status: "pending", words: nil))?.transcriptionStatus, "failed")
        for status in ["failed", "transcribed", "complete", "deferred", ""] {
            XCTAssertNil(OrphanedTranscription.settled(margin(id: "a", status: status, words: nil)), status)
        }
    }

    // MARK: Fixtures

    // MARK: Finding the one Margin a result is for

    /// #2509: a transcription or source-window result used to decode every Margin of its session, transcripts
    /// included, on the main thread to find the one it updates. It reads that Margin by id.
    func testAResultReadsOnlyItsOwnMarginNotTheWholeSession() throws {
        let meter = StoreReadMeter()
        let (store, engine) = try makeEngine(path: makePath(), readMeter: meter)
        for index in 0..<30 {
            try store.saveInterjection(margin(id: "m\(index)", status: "pending", words: String(repeating: "words ", count: 300)))
        }
        meter.reset()

        _ = try engine.transcriptionCompleted(interjectionId: "m7", sessionId: "session-A", transcript: "Heard")
        _ = try engine.sourceWindowContextPending(interjectionId: "m8", sessionId: "session-A")
        _ = try engine.transcriptionRetryFailed(interjectionId: "m9", sessionId: "session-A", error: "boom")

        XCTAssertNil(meter.totals()["loadInterjections(sessionId:)"], "no result decodes the session's other Margins")
        let stored = Dictionary(uniqueKeysWithValues: try store.loadInterjections(sessionId: "session-A").map { ($0.id, $0) })
        XCTAssertEqual(stored["m7"]?.transcript, "Heard")
        XCTAssertEqual(stored["m7"]?.transcriptionStatus, "transcribed")
        XCTAssertEqual(stored["m8"]?.anchorContextStatus, .pending)
        XCTAssertEqual(stored["m9"]?.transcriptionStatus, "failed", "a pending Margin whose retry failed is settled")
        XCTAssertEqual(stored["m6"]?.transcriptionStatus, "pending", "the others are untouched")
        XCTAssertThrowsError(
            try engine.transcriptionCompleted(interjectionId: "m7", sessionId: "session-B", transcript: "Wrong"),
            "a Margin is found only in its own session")
    }

    private func makePath() -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-orphaned-transcription-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return path
    }

    private func makeEngine(path: String, readMeter: StoreReadMeter? = nil) throws -> (SQLiteSessionStore, SessionEngine) {
        let store = try SQLiteSessionStore(path: path, readMeter: readMeter)
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        try store.saveItem(item)
        for id in ["session-A", "session-B"] {
            try store.saveSession(Session(
                id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1
            ))
        }
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone / Tablet Online", capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"],
            ]),
            repository: store
        )
        return (store, engine)
    }

    private func margin(id: String, status: String, words: String?) -> Interjection {
        Interjection(
            id: id, itemId: "item-text", sessionId: "session-A", targetType: .item, targetId: "item-text",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: "interjections/\(id).m4a", audioStatus: "saved", transcriptionStatus: status,
            transcript: words, cleanedTranscript: words, displayText: words, status: "active"
        )
    }
}
