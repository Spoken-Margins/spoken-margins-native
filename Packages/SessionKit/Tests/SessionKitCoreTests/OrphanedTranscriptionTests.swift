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

        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Again")
        let stored = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertEqual(stored.transcriptionStatus, "transcribed")
        XCTAssertEqual(stored.transcript, "Again")
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

    private func makePath() -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-orphaned-transcription-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return path
    }

    private func makeEngine(path: String) throws -> (SQLiteSessionStore, SessionEngine) {
        let store = try SQLiteSessionStore(path: path)
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
