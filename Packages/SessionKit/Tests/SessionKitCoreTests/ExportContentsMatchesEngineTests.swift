import Foundation
import XCTest
@testable import SessionKit

/// #4956: the Export screen dims the Margins toggle under No Margins and the Summaries and AI Replies toggle under
/// No Margins and My Margins, saying the choice leaves them out. This pins that the words agree with what the engine
/// actually exports for each choice, so a later change to the scope rules can't make the screen lie again.
final class ExportContentsMatchesEngineTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"]
        ]
    )

    func testEachContentsChoiceExportsWhatItsWordsSay() throws {
        let item = Item(
            id: "item-4956", title: "Article", mediaType: "text",
            text: String(repeating: "Source text. ", count: 40), externalReference: nil, status: "ready"
        )
        let session = Session(
            id: "session-4956", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: 30), completionPercent: 6, playbackRate: 1
        )
        let turnText = String(repeating: "A long answer sentence. ", count: 10).trimmingCharacters(in: .whitespaces)
        let turn = ConversationTurn(
            id: "turn-4956", sessionId: session.id, role: "assistant", turnType: "assistant_response",
            status: "complete", summary: nil, text: turnText, rawText: nil, chapters: nil, sourceInterjectionIds: []
        )
        let itemMargin = Interjection(
            id: "ij-item-4956", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
            createdAt: Date(), roughPercent: 5,
            anchor: Anchor(anchorType: .text, startChar: 20, endChar: 40, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "On the item",
            cleanedTranscript: nil, displayText: "On the item", status: "active"
        )
        let turnMargin = Interjection(
            id: "ij-turn-4956", itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: turn.id,
            createdAt: Date(), roughPercent: 50,
            anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 10, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "On the turn",
            cleanedTranscript: nil, displayText: "On the turn", status: "active"
        )
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: [itemMargin.id: itemMargin, turnMargin.id: turnMargin], turns: [turn.id: turn]
        )
        let engine = SessionEngine(profile: profile, repository: repository)

        for contents in ExportContents.allCases {
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: session.id, includeFullText: false, includeReference: false, includeListeningMap: false,
                includeInterjections: true, includeTurns: true, scope: contents.tag
            ))
            let marginIds = Set(export.interjections.map(\.id))
            let label = contents.label
            XCTAssertEqual(marginIds.contains(itemMargin.id), !contents.leavesOutMargins,
                           "\(label): a Margin on the item")
            XCTAssertEqual(export.turns.contains { $0.id == turn.id }, !contents.leavesOutReflections,
                           "\(label): an AI reply from Reflect")
            XCTAssertEqual(marginIds.contains(turnMargin.id), !contents.leavesOutReflections,
                           "\(label): a Margin on an AI reply")
        }
    }
}
