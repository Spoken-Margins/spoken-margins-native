import Foundation
import XCTest
@testable import SessionKit

/// #4205: a Margin on an AI answer or an interjection summary is a place inside that generated turn, not progress
/// through the item. The turn's place was written to the session's percent, so a Margin near the end of a turn
/// marked a text item the listener had barely started as finished, and the Library's default Unfinished view
/// hid it (#4103).
final class GeneratedTurnMarginPercentTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"]
        ]
    )

    /// An unfinished text item at 6%, with a generated turn of `turnType` and a Margin on the turn at `fraction` of it.
    private func engine(
        targetType: InterjectionTargetType, turnType: String, fraction: Double
    ) -> (engine: SessionEngine, repository: InMemorySessionRepository, note: Interjection) {
        let item = Item(
            id: "item-4205", title: "Article", mediaType: "text",
            text: String(repeating: "Source text. ", count: 40), externalReference: nil, status: "ready"
        )
        let session = Session(
            id: "session-4205", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: 30), completionPercent: 6, playbackRate: 1
        )
        let text = String(repeating: "A long answer sentence. ", count: 10).trimmingCharacters(in: .whitespaces)
        let turn = ConversationTurn(
            id: "turn-4205", sessionId: session.id, role: "assistant", turnType: turnType, status: "complete",
            summary: nil, text: text, rawText: nil, chapters: nil, sourceInterjectionIds: []
        )
        let start = Int(Double(text.count) * fraction)
        let note = Interjection(
            id: "ij-4205", itemId: item.id, sessionId: session.id, targetType: targetType, targetId: turn.id,
            createdAt: Date(), roughPercent: 50,
            anchor: Anchor(anchorType: .turn, startChar: start, endChar: text.count, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note",
            cleanedTranscript: nil, displayText: "Note", status: "active"
        )
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: [note.id: note], turns: [turn.id: turn]
        )
        return (SessionEngine(profile: profile, repository: repository), repository, note)
    }

    func testAMarginNearTheEndOfAGeneratedTurnDoesNotFinishTheItem() throws {
        let cases: [(name: String, targetType: InterjectionTargetType, turnType: String, playing: TargetType)] = [
            ("assistant turn", .assistantTurn, "assistant_response", .assistantTurnTTS),
            ("summary turn", .summaryTurn, "interjection_summary", .summaryTurnTTS)
        ]
        for turnCase in cases {
            for fraction in [1.0, 0.99, 0.5, 0.0] {
                let rig = engine(targetType: turnCase.targetType, turnType: turnCase.turnType, fraction: fraction)
                let label = "\(turnCase.name) at \(fraction)"

                _ = try rig.engine.playInterjectionAnchor(rig.note)

                let stored = try XCTUnwrap(rig.repository.loadSession(id: "session-4205"), label)
                XCTAssertEqual(stored.currentTargetType, turnCase.playing, "\(label): the turn is what plays")
                XCTAssertEqual(stored.completionPercent, 6, "\(label): the turn's place leaves the item's percent alone")
                XCTAssertNil(try rig.repository.loadItem(id: "item-4205").sourceCompletedAt, "\(label): the item is not finished")
            }
        }
    }

    /// #3930 stays: a Margin on the item's own text, made as it was read to its end, still finishes the item.
    func testAMarginAtTheEndOfTheItemsOwnTextStillFinishesIt() throws {
        let item = Item(
            id: "item-4205-own", title: "Own", mediaType: "text", text: "Short article text.",
            externalReference: nil, status: "ready"
        )
        let session = Session(
            id: "session-4205-own", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(),
            completionPercent: 0, playbackRate: 1
        )
        let length = item.text?.count ?? 0
        let note = Interjection(
            id: "ij-4205-own", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
            createdAt: Date(), roughPercent: 100,
            anchor: Anchor(anchorType: .text, startChar: length, endChar: length, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note",
            cleanedTranscript: nil, displayText: "Note", status: "active"
        )
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note]
        )
        let engine = SessionEngine(profile: profile, repository: repository)

        _ = try engine.playInterjectionAnchor(note)

        XCTAssertNotNil(try repository.loadItem(id: item.id).sourceCompletedAt)
    }
}
