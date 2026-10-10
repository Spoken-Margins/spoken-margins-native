import Foundation
import XCTest
@testable import SessionKit

final class DiscussionContextCandidateTests: XCTestCase {
    func testSummarySchemaKeysAndNullIntent() throws {
        try assertJSON(context(), """
        {"schemaVersion":"session-export.v1","item":{"title":"Article","text":"Body"},
        "listeningMap":{"overview":"Overview","chapters":[{"title":"Opening","startChar":0,"endChar":4}]},
        "interjections":[],"primaryUserIntent":null,"recentTurns":[],"currentFollowUp":null}
        """)
    }

    func testConversationSchemaAndIntentSources() throws {
        for (explicit, notes, source) in [
            (" typed ", [note()], "typed_follow_up"),
            (" \n", [], "conversation_continuation"),
            ("", [note()], "target_interjections")
        ] {
            let records = notes.isEmpty ? "[]" : """
            [{"targetType":"item","anchorBefore":"Before","anchorAfter":"After",
            "transcriptionStatus":"transcribed","transcript":"pending"}]
            """
            try assertJSON(context(notes: notes, followUp: "Request", explicit: explicit, primary: notes), """
            {"schemaVersion":"conversation-context.v2","item":{"title":"Article","text":"Body"},
            "listeningMap":{"overview":"Overview","chapters":[{"title":"Opening","startChar":0,"endChar":4}]},
            "interjections":\(records),"primaryUserIntent":{"source":"\(source)","request":"Request",
            "targetType":"item_text_tts","target":{"targetType":"item_text_tts","title":"Article","overview":"Overview"},
            "interjections":\(records)},"recentTurns":[],"currentFollowUp":"Request"}
            """)
        }
    }

    func testTranscriptFallbackInBothInterjectionLists() throws {
        let notes = [note(cleaned: "Clean", transcript: "Raw"), note(transcript: "Raw"), note(), note(cleaned: "", transcript: "Raw")]
        let json = try decode(context(notes: notes, followUp: "Request", primary: notes))
        let expected = try decode("""
        {"records":[
        {"targetType":"item","anchorBefore":"Before","anchorAfter":"After","transcriptionStatus":"transcribed","transcript":"Clean"},
        {"targetType":"item","anchorBefore":"Before","anchorAfter":"After","transcriptionStatus":"transcribed","transcript":"Raw"},
        {"targetType":"item","anchorBefore":"Before","anchorAfter":"After","transcriptionStatus":"transcribed","transcript":"pending"},
        {"targetType":"item","anchorBefore":"Before","anchorAfter":"After","transcriptionStatus":"transcribed","transcript":""}]}
        """)
        XCTAssertEqual(json["interjections"] as? NSArray, expected["records"] as? NSArray)
        let intent = try XCTUnwrap(json["primaryUserIntent"] as? NSDictionary)
        XCTAssertEqual(intent["interjections"] as? NSArray, expected["records"] as? NSArray)
    }

    func testRecentTurnsKeepsLastSixAndTextFallbackOrder() throws {
        let turns = [turn("excluded"), turn("first", summary: "Summary", text: "Text", raw: "Raw"),
                     turn("second", text: "Text", raw: "Raw"), turn("third", raw: "Raw"),
                     turn("fourth"), turn("fifth", summary: "", text: "Ignored"), turn("sixth", text: "Last")]
        let json = try decode(context(turns: turns))
        let expected = try decode("""
        {"recentTurns":[
        {"role":"assistant","turnType":"assistant_response","text":"Summary"},
        {"role":"assistant","turnType":"assistant_response","text":"Text"},
        {"role":"assistant","turnType":"assistant_response","text":"Raw"},
        {"role":"assistant","turnType":"assistant_response","text":""},
        {"role":"assistant","turnType":"assistant_response","text":""},
        {"role":"assistant","turnType":"assistant_response","text":"Last"}]}
        """)
        XCTAssertEqual(json["recentTurns"] as? NSArray, expected["recentTurns"] as? NSArray)
    }

    func testTargetContextLooksUpTurnIdOnlyForTurnPlayback() throws {
        let turns = [turn("old", summary: "Wrong", text: "Wrong"), turn("wanted", summary: "Summary", text: "Text", raw: "Raw")]
        for type in [TargetType.summaryTurnTTS, .assistantTurnTTS] {
            let actual = DiscussionContext.targetContext(itemTitle: "Article", overview: "Overview", turns: turns,
                                                        currentTargetType: type.rawValue, currentTargetId: "wanted")
            let expected = try decode("""
            {"targetType":"\(type.rawValue)","role":"assistant","turnType":"assistant_response","summary":"Summary","text":"Text"}
            """)
            XCTAssertEqual(actual as NSDictionary, expected)
            let json = try decode(context(turns: turns, followUp: "Request", target: type.rawValue, targetId: "wanted"))
            XCTAssertEqual((json["primaryUserIntent"] as? NSDictionary)?["target"] as? NSDictionary, expected)
        }
        let fallbacks: [(String, String?)] = [
            (TargetType.summaryTurnTTS.rawValue, "missing"), (TargetType.assistantTurnTTS.rawValue, nil),
            (TargetType.itemTextTTS.rawValue, "wanted"), ("unknown", "wanted")
        ]
        for (type, id) in fallbacks {
            let actual = DiscussionContext.targetContext(itemTitle: "Article", overview: "Overview", turns: turns,
                                                        currentTargetType: type, currentTargetId: id)
            XCTAssertEqual(actual as NSDictionary, try decode("""
            {"targetType":"item_text_tts","title":"Article","overview":"Overview"}
            """))
        }
        let raw = DiscussionContext.targetContext(itemTitle: "Article", overview: "Overview", turns: [turn("raw", raw: "Raw")],
                                                  currentTargetType: TargetType.assistantTurnTTS.rawValue, currentTargetId: "raw")
        XCTAssertEqual(raw["text"] as? String, "Raw")
        let blank = DiscussionContext.targetContext(itemTitle: "Article", overview: "Overview", turns: [turn("blank")],
                                                    currentTargetType: TargetType.summaryTurnTTS.rawValue, currentTargetId: "blank")
        XCTAssertEqual(blank["summary"] as? String, "")
        XCTAssertEqual(blank["text"] as? String, "")
    }

    func testPrimaryRequestTrimsAndUsesTranscriptThenDisplayFallback() {
        let notes = [note(cleaned: " Clean \n", transcript: "Ignored"), note(transcript: " Raw "),
                     note(display: " Display "), note(display: " \n")]
        XCTAssertEqual(DiscussionContext.primaryRequest(explicitFollowUp: " Typed \n", currentInterjections: notes), "Typed")
        XCTAssertEqual(DiscussionContext.primaryRequest(explicitFollowUp: " \n", currentInterjections: notes),
                       "Respond to the current conversation change expressed in these interjections.\n- Clean\n- Raw\n- Display")
        for empty in [[], [note()], [note(cleaned: " ", transcript: "Ignored")]] {
            XCTAssertEqual(DiscussionContext.primaryRequest(explicitFollowUp: "", currentInterjections: empty),
                           "Continue the discussion from the latest change in the conversation.")
        }
    }

    func testCurrentTargetInterjectionsPreservesOrderAndScope() {
        let notes = [note(id: "item1"), note(id: "summary1", type: .summaryTurn, target: "turn"),
                     note(id: "assistant1", type: .assistantTurn, target: "turn"), note(id: "item2"),
                     note(id: "other", type: .assistantTurn, target: "other"), note(id: "assistant2", type: .assistantTurn, target: "turn"),
                     note(id: "otherItem", target: "other")]
        for (type, ids) in [(TargetType.summaryTurnTTS.rawValue, ["summary1"]),
                            (TargetType.assistantTurnTTS.rawValue, ["assistant1", "assistant2"]),
                            (TargetType.itemTextTTS.rawValue, ["item1", "item2"]), ("unknown", ["item1", "item2"])] {
            XCTAssertEqual(DiscussionContext.currentTargetInterjections(interjections: notes, currentTargetType: type,
                                                                         currentTargetId: "turn", itemId: "item").map(\.id), ids)
        }
        XCTAssertTrue(DiscussionContext.currentTargetInterjections(interjections: notes, currentTargetType: TargetType.summaryTurnTTS.rawValue,
                                                                   currentTargetId: nil, itemId: "item").isEmpty)
    }

    private func context(notes: [Interjection] = [], turns: [ConversationTurn] = [], followUp: String? = nil,
                         explicit: String? = nil, primary: [Interjection] = [], target: String = TargetType.itemTextTTS.rawValue,
                         targetId: String? = "item") -> String {
        DiscussionContext.contextJSON(itemTitle: "Article", itemText: "Body", overview: "Overview",
                                      chapters: [Chapter(id: "chapter", title: "Opening", startChar: 0, endChar: 4, percent: 0)],
                                      turns: turns, currentTargetType: target, currentTargetId: targetId,
                                      interjections: notes, currentFollowUp: followUp, explicitFollowUp: explicit, primaryInterjections: primary)
    }

    private func note(id: String = "note", type: InterjectionTargetType = .item, target: String = "item",
                      cleaned: String? = nil, transcript: String? = nil, display: String? = nil) -> Interjection {
        Interjection(id: id, itemId: "item", sessionId: "session", targetType: type, targetId: target,
                     createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
                     anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "Before", anchorAfter: "After"),
                     audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed",
                     transcript: transcript, cleanedTranscript: cleaned, displayText: display, status: "active")
    }

    private func turn(_ id: String, summary: String? = nil, text: String? = nil, raw: String? = nil) -> ConversationTurn {
        ConversationTurn(id: id, sessionId: "session", role: "assistant", turnType: "assistant_response", status: "ready",
                         summary: summary, text: text, rawText: raw, sourceInterjectionIds: [])
    }

    private func decode(_ json: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    private func assertJSON(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try decode(actual), try decode(expected), file: file, line: line)
    }
}
