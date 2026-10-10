import Foundation
import XCTest
@testable import SessionKit

/// How much text a Margin on written text carries on each side of the place it was recorded: the sentence it
/// was recorded in, plus three more each way, i.e. four sentence units (`textAnchorShoulderSentenceCount`).
/// A recipient needs to match this text to place the Margin in their own copy, and a packet carries it, so the
/// size matters both ways.
///
/// The Mac-only `testTextInterjectionAnchorUsesFullWordsAndFourSentenceShoulders` uses a seven-sentence text with
/// the Margin in the fourth sentence, so there are exactly four units on each side and a shoulder of five or of
/// four hundred gives the same text. `testAssistantTurnExportRehydratesLegacyAnchorsAndUsesContextualLayout`
/// never checks that a sentence outside the shoulder is absent. Here the text is long enough that the shoulder
/// stops well inside it, and the first sentence outside is checked to be missing.
final class TextAnchorShoulderTests: XCTestCase {
    private let source = [
        "Alpha opens the case.", "Bravo gives the history.", "Charlie adds the evidence.", "Delta weighs the cost.",
        "Echo tests the claim.", "Foxtrot offers a counterpoint.", "Golf discusses music and its role.",
        "Hotel draws a conclusion.", "India raises an objection.", "Juliet answers it.", "Kilo adds a caveat.",
        "Lima summarizes the position.", "Mike proposes a follow up.", "November closes the argument.",
    ]

    /// Reports a fixed playhead, like a speech player paused on a word.
    private final class FixedPlayer: AudioPlaybackClient {
        var offset = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws {}
        func currentCharOffset() -> Int? { offset }
        func pause() throws {}
    }

    func testASpokenMarginInTheMiddleOfALongTextCarriesFourSentenceUnitsEachWay() throws {
        let text = source.joined(separator: " ")
        let item = Item(id: "item-long-text", title: "Long text", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let player = FixedPlayer()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone/Tablet Online", capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"],
            ]),
            repository: repository, audio: player
        )
        _ = try engine.startSession(itemId: item.id)
        // One character into "music": the Margin is anchored after the whole word.
        let music = try XCTUnwrap(text.range(of: "music")).lowerBound
        player.offset = text.distance(from: text.startIndex, to: music) + 1

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/long.m4a")

        let anchor = try XCTUnwrap(try repository.loadInterjections(sessionId: engine.currentSession?.id ?? "").first).anchor
        XCTAssertEqual(
            anchor.anchorBefore,
            "Delta weighs the cost. Echo tests the claim. Foxtrot offers a counterpoint. Golf discusses music",
            "the sentence it was recorded in, up to the word, and the three sentences before it"
        )
        XCTAssertEqual(
            anchor.anchorAfter,
            "and its role. Hotel draws a conclusion. India raises an objection. Juliet answers it.",
            "the rest of that sentence and the three after it"
        )
        XCTAssertFalse(anchor.anchorBefore.contains("Charlie"), "the fifth unit back is outside the shoulder")
        XCTAssertFalse(anchor.anchorAfter.contains("Kilo"), "the fifth unit forward is outside the shoulder")
    }

    /// An export rebuilds the context of a Margin on an AI reply from the turn's text. A Margin saved by a
    /// current build stores the playhead in `startChar`; an older one stored the sentence it was in as its
    /// "before", and the end of that sentence is the best split. Both should give the same four-unit shoulders.
    func testAnExportedMarginOnAnAIReplyCarriesFourSentenceUnitsEachWayForCurrentAndLegacyAnchors() throws {
        let sentences = [
            "One opens.", "Two expands.", "Three qualifies.", "Four tests.", "Five is interrupted.", "Six continues.",
            "Seven compares.", "Eight concludes.", "Nine adds an appendix.", "Ten closes.", "Eleven repeats.", "Twelve ends.",
        ]
        let reply = sentences.joined(separator: " ")
        let item = Item(id: "item-turn-export", title: "Turn Export", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(
            id: "session-turn-export", itemId: item.id, status: "in_progress", phase: .conversation,
            currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1
        )
        let turn = ConversationTurn(
            id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete",
            summary: nil, text: reply, rawText: reply, sourceInterjectionIds: []
        )
        func range(of sentence: String) throws -> (start: Int, end: Int) {
            let found = try XCTUnwrap(reply.range(of: sentence))
            return (reply.distance(from: reply.startIndex, to: found.lowerBound), reply.distance(from: reply.startIndex, to: found.upperBound))
        }
        func margin(_ id: String, covering sentence: String, before: String) throws -> Interjection {
            let covered = try range(of: sentence)
            return Interjection(
                id: id, itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: turn.id,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
                anchor: Anchor(anchorType: .turn, startChar: covered.start, endChar: covered.end, anchorBefore: before, anchorAfter: "stored after"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                transcript: "Listener note.", cleanedTranscript: nil, displayText: nil, status: "active"
            )
        }
        // Current: recorded at the start of "Six continues." Legacy: its "before" is the sentence it was in, "Five is interrupted.".
        let current = try margin("ij-current", covering: "Six continues.", before: "stored before")
        let legacy = try margin("ij-legacy", covering: "Five is interrupted.", before: "Five is interrupted.")
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: [current.id: current, legacy.id: legacy], turns: [turn.id: turn]
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone/Tablet Online", capabilities: ["sync": ["canonical_persistence"]]),
            repository: repository
        )

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: false, includeReference: false,
            includeListeningMap: false, includeInterjections: true, includeTurns: false
        ))

        for exported in export.interjections {
            XCTAssertEqual(exported.anchorBefore, "Two expands. Three qualifies. Four tests. Five is interrupted.", exported.id)
            XCTAssertEqual(exported.anchorAfter, "Six continues. Seven compares. Eight concludes. Nine adds an appendix.", exported.id)
            XCTAssertFalse(exported.anchorBefore.contains("One opens."), "the fifth unit back is outside the shoulder: \(exported.id)")
            XCTAssertFalse(exported.anchorAfter.contains("Ten closes."), "the fifth unit forward is outside the shoulder: \(exported.id)")
        }
        XCTAssertEqual(export.interjections.map(\.id).sorted(), ["ij-current", "ij-legacy"])
    }
}
