import Foundation
import XCTest
@testable import SessionKit

/// #4924: the Add Voice Margin action given a Library item saves a recording as a spoken Margin on that item's saved
/// session, at its saved place, the way Add Margin saves words (`StoredSessionMargin.addWritten`).
final class StoredSpokenMarginTests: XCTestCase {
    private let savedText = "First sentence. Second sentence. Third sentence."
    private let savedOffset = 16 // the start of "Second sentence."
    private let audioPath = "SpokenMargins/interjections/shortcut-voice-abc.m4a"

    private var savedItem: Item {
        Item(id: "item-saved", title: "Saved", mediaType: "text", text: savedText, externalReference: nil, status: "ready")
    }

    private func savedSession(updatedAt: Date? = nil) -> Session {
        Session(
            id: "session-saved", itemId: savedItem.id, createdAt: updatedAt, updatedAt: updatedAt, status: "in_progress",
            phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: savedItem.id,
            position: Position(charOffset: savedOffset), completionPercent: 33, playbackRate: 1
        )
    }

    private func repository(sessions: [Session]? = nil, items: [Item]? = nil) -> InMemorySessionRepository {
        let items = items ?? [savedItem]
        let sessions = sessions ?? [savedSession()]
        return InMemorySessionRepository(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
            interjections: [:]
        )
    }

    func testSavesTheRecordingAsASpokenMarginAtTheSavedPlace() throws {
        let repository = repository()

        let saved = try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: savedItem.id, repository: repository)

        let margin = saved.interjection
        XCTAssertEqual(saved.itemTitle, "Saved")
        XCTAssertEqual(margin.itemId, savedItem.id)
        XCTAssertEqual(margin.sessionId, "session-saved")
        XCTAssertEqual(margin.audioPath, audioPath, "the Margin's voice is the recording")
        XCTAssertEqual(margin.audioStatus, "saved")
        XCTAssertNotEqual(margin.captureKind, .written, "a spoken Margin, not a written one")
        XCTAssertEqual(margin.transcriptionStatus, "pending", "its words come from the ordinary transcription")
        XCTAssertNil(margin.transcript)
        XCTAssertEqual(margin.status, "active")
        XCTAssertEqual(margin.anchor.startChar, savedOffset)
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved"), [margin])
    }

    func testTheSavedSessionStaysWhereTheListenerLeftIt() throws {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let before = savedSession(updatedAt: stamp)
        let repository = repository(sessions: [before])

        _ = try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: savedItem.id, repository: repository)

        let after = try XCTUnwrap(repository.loadSession(id: before.id))
        XCTAssertEqual(after.position, before.position)
        XCTAssertEqual(after.completionPercent, before.completionPercent)
        XCTAssertEqual(after.phase, before.phase)
        XCTAssertEqual(after.updatedAt, stamp, "not pulled ahead of the item last listened to")
        XCTAssertEqual(repository.sessions.count, 1, "no session is created")
    }

    func testTwoRecordingsMakeTwoMargins() throws {
        let repository = repository()
        let first = try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: savedItem.id, repository: repository)
        let second = try StoredSessionMargin.addSpoken(
            audioPath: "SpokenMargins/interjections/shortcut-voice-def.m4a", itemId: savedItem.id, repository: repository
        )
        XCTAssertNotEqual(first.interjection.id, second.interjection.id)
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved").count, 2)
    }

    func testAnItemNotInTheLibraryIsRefusedAndNothingIsSaved() throws {
        let repository = repository()
        XCTAssertThrowsError(try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: "gone", repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .itemNotFound)
        }
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved"), [])
    }

    func testAnItemInRecentlyDeletedIsRefused() throws {
        var deleted = savedItem
        deleted.deletedAt = Date(timeIntervalSince1970: 5)
        let repository = repository(items: [deleted])
        XCTAssertThrowsError(try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: deleted.id, repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .itemNotFound)
        }
    }

    func testAnItemNeverStartedIsRefusedWithNoSession() throws {
        let repository = repository(sessions: [])
        XCTAssertThrowsError(try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: savedItem.id, repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .noSession)
        }
        XCTAssertTrue(repository.sessions.isEmpty)
    }

    func testAnEmptyPathSavesNothing() throws {
        let repository = repository()
        for path in ["", "   "] {
            XCTAssertThrowsError(try StoredSessionMargin.addSpoken(audioPath: path, itemId: savedItem.id, repository: repository), "'\(path)'")
        }
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved"), [])
    }

    /// The new engine step asks the ordinary transcription for the words, and a transcript that fails to schedule
    /// never turns a saved Margin into a failed save.
    func testTheEngineAsksForTheWordsAndTellsWhichMargin() throws {
        final class Scheduler: TranscriptionClient {
            var scheduled: [Interjection] = []
            var failing = false
            func scheduleTranscription(interjection: Interjection) throws {
                scheduled.append(interjection)
                if failing { throw SessionKitError.invalidCommandForState("scheduleTranscription") }
            }
        }
        for failing in [false, true] {
            let repository = repository()
            let scheduler = Scheduler()
            scheduler.failing = failing
            let engine = SessionEngine(
                profile: RuntimeCapabilityProfile(id: "t", displayName: "t", capabilities: [:]),
                repository: repository, transcriber: scheduler
            )
            try engine.inspectSession(sessionId: "session-saved")
            let capture = try engine.beginWrittenInterjection()
            try engine.saveSpokenInterjection(captureId: capture.id, audioRef: audioPath)
            let saved = try repository.loadInterjections(sessionId: "session-saved")
            XCTAssertEqual(saved.count, 1, "failing: \(failing)")
            XCTAssertEqual(scheduler.scheduled.map(\.id), saved.map(\.id))
            XCTAssertEqual(engine.lastScheduledTranscriptionInterjectionId, saved.first?.id)
        }
    }

    func testTheEngineStepRefusesAnotherCapturesIdAndKeepsTheCaptureOpen() throws {
        let repository = repository()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "t", displayName: "t", capabilities: [:]), repository: repository
        )
        try engine.inspectSession(sessionId: "session-saved")
        let capture = try engine.beginWrittenInterjection()
        XCTAssertThrowsError(try engine.saveSpokenInterjection(captureId: "other", audioRef: audioPath))
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved"), [])
        // The capture is still the pending one, so the right id saves.
        XCTAssertNoThrow(try engine.saveSpokenInterjection(captureId: capture.id, audioRef: audioPath))
    }
}
