import Foundation
import XCTest
@testable import SessionKit

/// #826: a Notes summary is shown as a Margin Summary in the timeline and in export, while its stored
/// turn type stays `interjection_summary` for Build 29.
final class ConversationTurnTitleTests: XCTestCase {
    func testTitlesUseMarginSummaryAndKeepTheirNumbers() {
        XCTAssertEqual(ConversationTurnTitle.numbered(turn(id: "turn-summary-002", type: "interjection_summary")), "Margin Summary 2")
        XCTAssertEqual(ConversationTurnTitle.numbered(turn(id: "summary", type: "interjection_summary")), "Margin Summary 1")
        XCTAssertEqual(ConversationTurnTitle.numbered(turn(id: "turn-response-003", type: "assistant_response")), "AI Response 3")
        XCTAssertEqual(ConversationTurnTitle.numbered(turn(id: "response", type: "assistant_response")), "AI Response")
        XCTAssertEqual(ConversationTurnTitle.numbered(turn(id: "turn-004", type: "user_response")), "Follow-up")
        XCTAssertEqual(ConversationTurnTitle.plain(turnType: "interjection_summary"), "Margin Summary")
        XCTAssertEqual(ConversationTurnTitle.plain(turnType: "chapter_recap"), "Chapter Recap")
    }

    func testExportHeadsASummaryAndItsMarginsAsAMarginSummary() throws {
        let profile = RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone/Tablet Online", capabilities: [:])
        let item = Item(id: "item-summary-export", title: "Summary Export", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-summary-export", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        var summary = turn(id: "turn-summary-001", type: "interjection_summary")
        summary.sessionId = session.id
        let margin = Interjection(
            id: "ij-summary-001", itemId: item.id, sessionId: session.id,
            targetType: .summaryTurn, targetId: summary.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "Listener note.", cleanedTranscript: nil, displayText: nil, status: "active"
        )
        let repo = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: [margin.id: margin], turns: [summary.id: summary]
        )
        let engine = SessionEngine(profile: profile, repository: repo)
        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: false, includeReference: false, includeListeningMap: false,
            includeInterjections: true, includeTurns: true
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)

        XCTAssertTrue(markdown.contains("### Margin Summary\n"), markdown)
        XCTAssertTrue(markdown.contains("Margin Summary Context and Listener Interjections"), markdown)
        XCTAssertFalse(markdown.contains("Interjection Summary"), markdown)
        XCTAssertEqual(try repo.loadTurns(sessionId: session.id).map(\.turnType), ["interjection_summary"], "the stored type doesn't change")
    }

    private func turn(id: String, type: String) -> ConversationTurn {
        ConversationTurn(
            id: id, sessionId: "session", role: "assistant", turnType: type, status: "complete",
            summary: nil, text: "Body.", rawText: "Body.", sourceInterjectionIds: []
        )
    }
}
