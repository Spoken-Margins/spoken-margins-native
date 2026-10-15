import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class LocalSummaryCompletionTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Online", capabilities: ["ai": ["summarize_interjections"]])

    private func fixture() throws -> (SQLiteSessionStore, SessionEngine, LocalSummaryRequestOrigin) {
        let path = FileManager.default.temporaryDirectory.appending(path: "summary-success-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        for key in ["a", "b"] {
            try store.saveItem(Item(id: key, title: key, mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready"))
            try store.saveSession(Session(id: key, itemId: key, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: key, position: Position(), completionPercent: 0, playbackRate: 1))
            try store.saveInterjection(Interjection(id: "note-\(key)", itemId: key, sessionId: key, targetType: .item, targetId: key, createdAt: Date(), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "One.", anchorAfter: "Two."), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: nil, status: "active"))
            try store.saveTurn(ConversationTurn(id: "turn-summary-001", sessionId: key, role: "assistant", turnType: "interjection_summary", status: "pending", summary: nil, text: nil, rawText: nil, sourceInterjectionIds: ["note-\(key)"]))
            try store.saveAIJob(AIJob(id: "job-summary-001", kind: "interjection_summary", itemId: key, sessionId: key, turnId: "turn-summary-001", providerType: "apple_foundation_on_device", model: "system_language_model", status: "pending", attempts: 0, lastError: nil, messages: [], playbackMode: "item_text_tts"))
        }
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.inspectSession(sessionId: "a")
        return (store, engine, try engine.localSummaryRequestOrigin(itemId: "a", turnId: "turn-summary-001"))
    }

    func testNormalActiveCompletionPreservesSourceIDsAndUsesExistingParser() throws {
        for response in [
            "Plain response. Trailing fragment",
            "<sm_summary>Brief</sm_summary><sm_response>Full response.</sm_response><sm_chapters_json>{\"schemaVersion\":\"assistant-response-map.v1\",\"chapters\":[{\"id\":\"c\",\"title\":\"Chapter\",\"anchor\":\"Full\"}]}</sm_chapters_json>",
            "<sm_response>Incomplete tag with remaining text",
            "<sm_response>Good body.</sm_response><sm_chapters_json>{broken}</sm_chapters_json>"
        ] {
            let (store, engine, origin) = try fixture()
            _ = try engine.completeLocalSummary(origin: origin, content: response)
            let actual = try XCTUnwrap(store.loadTurns(sessionId: "a").first)
            XCTAssertEqual(actual.status, "complete")
            XCTAssertEqual(actual.sourceInterjectionIds, ["note-a"])
            XCTAssertEqual(try store.loadAIJobs(sessionId: "a").first?.status, "complete")
            XCTAssertEqual(engine.snapshot.turnStatus, "complete")
            XCTAssertEqual(engine.snapshot.pendingAiJobCount, 0)
            // Compare the established stream parser on an independent session, not a hand-written parser expectation.
            _ = try engine.inspectSession(sessionId: "b")
            _ = try engine.aiStreamDelta(turnId: origin.turnId, content: response)
            _ = try engine.aiJobCompleted(turnId: origin.turnId)
            let control = try XCTUnwrap(store.loadTurns(sessionId: "b").first)
            XCTAssertEqual(actual.text, control.text)
            XCTAssertEqual(actual.summary, control.summary)
            XCTAssertEqual(actual.chapters, control.chapters)
            XCTAssertEqual(actual.rawText, control.rawText)
        }
    }

    func testInactiveCompletionDoesNotDisturbAnotherSessionsStreamOrSnapshot() throws {
        let (store, engine, origin) = try fixture()
        _ = try engine.inspectSession(sessionId: "b")
        _ = try engine.aiStreamDelta(turnId: origin.turnId, content: "B first. ")
        let before = engine.snapshot
        _ = try engine.completeLocalSummary(origin: origin, content: "A only.")
        XCTAssertEqual(engine.snapshot, before)
        _ = try engine.aiStreamDelta(turnId: origin.turnId, content: "B last.")
        _ = try engine.aiJobCompleted(turnId: origin.turnId)
        XCTAssertEqual(try store.loadTurns(sessionId: "b").first?.rawText, "B first. B last.")
        XCTAssertEqual(try store.loadTurns(sessionId: "a").first?.rawText, "A only.")
    }

    func testFullResponseReplacesAnOriginalPartialUsingTheSameParser() throws {
        let (store, engine, origin) = try fixture()
        _ = try engine.aiStreamDelta(turnId: origin.turnId, content: "Partial text that is replaced.")
        _ = try engine.completeLocalSummary(origin: origin, content: "<sm_response>Complete result.</sm_response>")
        let turn = try XCTUnwrap(store.loadTurns(sessionId: "a").first)
        XCTAssertEqual(turn.text, "Complete result.")
        XCTAssertEqual(turn.status, "complete")
        XCTAssertEqual(turn.sourceInterjectionIds, ["note-a"])
    }

    func testDuplicateCompletionCannotOverwriteSavedContent() throws {
        let (store, engine, origin) = try fixture()
        _ = try engine.completeLocalSummary(origin: origin, content: "Original.")
        XCTAssertThrowsError(try engine.completeLocalSummary(origin: origin, content: "Duplicate.")) { XCTAssertTrue($0 is LocalSummaryRequestOrigin.Discarded) }
        XCTAssertEqual(try store.loadTurns(sessionId: "a").first?.rawText, "Original.")
    }

    func testDeletedOrDiscardedRequestCannotBeRecreated() throws {
        for mutation in ["trash", "delete", "cancel", "newAttempt", "removedNote"] {
            let (store, engine, origin) = try fixture()
            _ = try engine.inspectSession(sessionId: "b")
            switch mutation {
            case "trash": try store.moveItemToTrash(id: "a")
            case "delete": try store.deleteItem(id: "a")
            case "removedNote":
                var note = try XCTUnwrap(store.loadInterjections(sessionId: "a").first)
                note.status = "deleted"
                try store.saveInterjection(note)
            default:
                var job = try XCTUnwrap(store.loadAIJobs(sessionId: "a").first)
                if mutation == "cancel" { job.status = "cancelled" } else { job.attempts += 1 }
                try store.updateAIJob(job)
            }
            let turns = try store.loadTurns(sessionId: "a")
            let jobs = try store.loadAIJobs(sessionId: "a")
            let snapshot = engine.snapshot
            XCTAssertThrowsError(try engine.completeLocalSummary(origin: origin, content: "Too late."))
            XCTAssertEqual(try store.loadTurns(sessionId: "a"), turns, mutation)
            XCTAssertEqual(try store.loadAIJobs(sessionId: "a"), jobs, mutation)
            XCTAssertEqual(engine.snapshot, snapshot, mutation)
        }
    }

    func testSameItemNewSessionAndChangedTargetDoNotPublishCompletionIntoPlayback() throws {
        for newSession in [true, false] {
            let (store, engine, origin) = try fixture()
            var session = try XCTUnwrap(store.loadSession(id: "a"))
            if newSession { session.id = "a-new" } else { session.currentTargetId = "other-target" }
            try store.saveSession(session)
            _ = try engine.inspectSession(sessionId: session.id)
            let snapshot = engine.snapshot
            XCTAssertFalse(origin.matchesPlayback(snapshot))
            _ = try engine.completeLocalSummary(origin: origin, content: "Keep in original session.")
            XCTAssertEqual(engine.snapshot, snapshot)
            XCTAssertEqual(try store.loadTurns(sessionId: "a").first?.status, "complete")
            if newSession { XCTAssertTrue(try store.loadTurns(sessionId: "a-new").isEmpty) }
        }
    }
}
