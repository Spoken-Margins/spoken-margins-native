import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1469: a late failure of session A's summary must settle A's own job and turn, never
/// the job of whichever session is active when the failure arrives.
final class SummaryFailureOwnershipTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"], "ai": ["summarize_interjections"]]
    )

    private func seed(_ store: SQLiteSessionStore, key: String) throws -> Session {
        let item = Item(id: "item-\(key)", title: "Item \(key)", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let session = Session(id: "session-\(key)", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 20, playbackRate: 1)
        try store.saveItem(item)
        try store.saveSession(session)
        try store.saveInterjection(Interjection(
            id: "ij-\(key)", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 20,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "One.", anchorAfter: "Two."),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "I want to keep this \(key).", cleanedTranscript: nil, displayText: nil, status: "active"
        ))
        return session
    }

    private func makeStore() throws -> (SQLiteSessionStore, cleanup: () -> Void) {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-1469-\(UUID().uuidString).sqlite").path
        return (try SQLiteSessionStore(path: path), { try? FileManager.default.removeItem(atPath: path) })
    }

    /// Both sessions get a summary job and turn with the same ids (ids are per session).
    private func summaryState(_ store: SQLiteSessionStore, _ session: Session) throws -> (job: String?, turn: String?) {
        (try store.loadAIJobs(sessionId: session.id).last?.status, try store.loadTurns(sessionId: session.id).last?.status)
    }

    func testLateFailureOfSessionASettlesOnlyAWhileBHasItsOwnPendingSummary() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let a = try seed(store, key: "a"), b = try seed(store, key: "b")
        let engine = SessionEngine(profile: profile, repository: store)

        _ = try engine.inspectSession(sessionId: a.id)
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: a.id))
        _ = try engine.inspectSession(sessionId: b.id)
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: b.id))

        // A's request fails while B is the active session.
        _ = try engine.aiProviderFailed(error: "late failure of A", sessionId: a.id, turnId: "turn-summary-001")

        XCTAssertEqual(try summaryState(store, a).job, "retryable", "A's own job is settled")
        XCTAssertEqual(try summaryState(store, a).turn, "failed")
        XCTAssertEqual(try summaryState(store, b).job, "pending", "B's pending work is untouched")
        XCTAssertEqual(try summaryState(store, b).turn, "pending")
    }

    func testLateFailureOfSessionASettlesAWhenBHasNoPendingSummary() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let a = try seed(store, key: "a"), b = try seed(store, key: "b")
        let engine = SessionEngine(profile: profile, repository: store)

        _ = try engine.inspectSession(sessionId: a.id)
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: a.id))
        _ = try engine.inspectSession(sessionId: b.id)

        let snapshotBefore = engine.snapshot.turnStatus
        XCTAssertNoThrow(try engine.aiProviderFailed(error: "late failure of A", sessionId: a.id, turnId: "turn-summary-001"))

        XCTAssertEqual(try summaryState(store, a).job, "retryable", "A is not left pending")
        XCTAssertEqual(try summaryState(store, a).turn, "failed")
        XCTAssertTrue(try store.loadAIJobs(sessionId: b.id).isEmpty)
        XCTAssertEqual(engine.snapshot.turnStatus, snapshotBefore, "the active session's snapshot is not marked failed")

        // Back in A, recovery regenerates the failed summary instead of hitting
        // interjection_summary_already_current.
        _ = try engine.inspectSession(sessionId: a.id)
        XCTAssertNoThrow(try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: a.id)))
        XCTAssertEqual(try summaryState(store, a).turn, "pending")
    }

    func testAStaleTurnIdStillSettlesTheNamedSessionsOpenJobAndAMissingSessionThrows() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let a = try seed(store, key: "a"), b = try seed(store, key: "b")
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.inspectSession(sessionId: a.id)
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: a.id))
        _ = try engine.inspectSession(sessionId: b.id)
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: b.id))

        XCTAssertThrowsError(try engine.aiProviderFailed(error: "x", sessionId: "session-gone", turnId: "turn-summary-001"))
        XCTAssertEqual(try summaryState(store, a).job, "pending", "a missing session changes nothing")
        XCTAssertEqual(try summaryState(store, b).job, "pending")

        _ = try engine.aiProviderFailed(error: "x", sessionId: a.id, turnId: "turn-stale")
        XCTAssertEqual(try summaryState(store, a).job, "retryable", "A is settled even when the app's turn id is stale")
        XCTAssertEqual(try summaryState(store, b).job, "pending", "and B is still untouched")
    }
}
