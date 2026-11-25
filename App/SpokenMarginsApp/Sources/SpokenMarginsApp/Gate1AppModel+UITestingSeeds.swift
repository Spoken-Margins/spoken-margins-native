import Foundation
import SessionKit
import SessionKitPersistence

/// UI-testing content seeds (#986), moved unchanged out of the central model.
/// Startup ordering, launch hooks and every stored property remain in Gate1AppModel.
extension Gate1AppModel {
    #if DEBUG
    /// Tests that model a write through the app must share its serialized connection.
    /// Opening another connection also races unrelated offline-ledger startup work.
    func libraryStoreForTesting() throws -> SQLiteSessionStore {
        precondition(Self.isRunningUnitTests)
        return try requireStore()
    }
    #endif

    func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard UITestingHooks.seed.seedsGeneratedTimeline,
              try store.loadTurns(sessionId: sessionId).isEmpty else {
            return
        }
        // Leaves a playing start playing (#5204): the seed used to pause every fixture-article start.
        snapshot = try UITestingGeneratedTimeline.seed(sessionId: sessionId, engine: engine)
    }

    func seedUITestingSummaryInterjectionIfNeeded(
        sessionId: String,
        engine: SessionEngine,
        store: SQLiteSessionStore
    ) throws {
        guard let note = UITestingHooks.summaryInterjectionNote,
              try store.loadInterjections(sessionId: sessionId).isEmpty else { return }
        let interjection = Interjection(
            id: "ij-ui-summary",
            itemId: activeItemId,
            sessionId: sessionId,
            targetType: .item,
            targetId: activeItemId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: snapshot.sourceProgressPercent,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: min(24, selectedItem.text.count),
                anchorBefore: String(selectedItem.text.prefix(120)),
                anchorAfter: ""
            ),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: note,
            cleanedTranscript: nil,
            displayText: note,
            status: "active",
            anchorContextStatus: .ready
        )
        try store.saveInterjection(interjection)
        snapshot = try engine.inspectSession(sessionId: sessionId)
        diagnostics["uiTestSummaryFixture"] = interjection.id
    }
}
