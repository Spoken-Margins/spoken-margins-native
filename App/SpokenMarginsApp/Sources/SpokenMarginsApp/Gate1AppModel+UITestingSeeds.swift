import Foundation
import SessionKit
import SessionKitPersistence

/// UI-testing content seeds (#986), moved unchanged out of the central model.
/// Startup ordering, launch hooks and every stored property remain in Gate1AppModel.
extension Gate1AppModel {
    func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard UITestingHooks.seed.seedsGeneratedTimeline,
              try store.loadTurns(sessionId: sessionId).isEmpty else {
            return
        }
        _ = try engine.submitFollowup(text: "Can you respond to my interjection?")
        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: """
            <sm_summary>Here is a quick response to your interjection.</sm_summary>
            <sm_response>Here is a quick response to your interjection. First, your test is checking whether generated turns stay easy to navigate. Second, the response chapters should remain tappable in the main timeline.</sm_response>
            <sm_chapters_json>{"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ai-ch-1","title":"Quick Response","anchor":"Here is a quick response"},{"id":"ai-ch-2","title":"Timeline Navigation","anchor":"Second, the response chapters"}]}</sm_chapters_json>
            """
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")
        snapshot = try engine.inspectSession(sessionId: sessionId)
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
