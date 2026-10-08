import Foundation
import XCTest
@testable import SessionKit

/// The JSON that Discuss and the Margin summary send to the AI provider, and the rules for which Margins a
/// conversation change is about. Linux and Mac compare the parsed JSON, because pretty-printing can differ
/// between platforms; the exact text is pinned by one Mac-host test in SessionKitTests.
final class DiscussionContextTests: XCTestCase {
    // MARK: - Fixtures

    private func margin(
        _ id: String,
        _ targetType: InterjectionTargetType = .item,
        target: String = "item-1",
        cleaned: String? = nil,
        transcript: String? = nil,
        display: String? = nil,
        before: String = "before",
        after: String = "after",
        status: String = "transcribed"
    ) -> Interjection {
        Interjection(
            id: id,
            itemId: "item-1",
            sessionId: "session-1",
            targetType: targetType,
            targetId: target,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 8, anchorBefore: before, anchorAfter: after),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: status,
            transcript: transcript,
            cleanedTranscript: cleaned,
            displayText: display,
            status: "active"
        )
    }

    private func turn(
        _ id: String,
        role: String = "assistant",
        type: String = "assistant_response",
        summary: String? = nil,
        text: String? = nil,
        raw: String? = nil
    ) -> ConversationTurn {
        ConversationTurn(
            id: id, sessionId: "session-1", role: role, turnType: type, status: "done",
            summary: summary, text: text, rawText: raw, sourceInterjectionIds: []
        )
    }

    private let chapters = [
        Chapter(id: "c1", title: "Opening", startChar: 0, endChar: 120, percent: 0),
        Chapter(id: "c2", title: "Middle", startChar: 120, endChar: 400, percent: 30)
    ]

    private func context(
        turns: [ConversationTurn] = [],
        targetType: String = TargetType.itemTextTTS.rawValue,
        targetId: String? = "item-1",
        interjections: [Interjection] = [],
        followUp: String? = nil,
        explicit: String? = nil,
        primary: [Interjection] = []
    ) throws -> [String: Any] {
        let json = DiscussionContext.contextJSON(
            itemTitle: "The Title",
            itemText: "The body text.",
            overview: "The overview.",
            chapters: chapters,
            turns: turns,
            currentTargetType: targetType,
            currentTargetId: targetId,
            interjections: interjections,
            currentFollowUp: followUp,
            explicitFollowUp: explicit,
            primaryInterjections: primary
        )
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - Context JSON

    func testSummaryContextHasTheSessionExportShapeAndNullIntent() throws {
        let parsed = try context(interjections: [margin("a", cleaned: "A note.")])

        XCTAssertEqual(parsed["schemaVersion"] as? String, "session-export.v1")
        XCTAssertEqual(
            Set(parsed.keys),
            ["schemaVersion", "item", "listeningMap", "interjections", "primaryUserIntent", "recentTurns", "currentFollowUp"]
        )
        XCTAssertTrue(parsed["primaryUserIntent"] is NSNull)
        XCTAssertTrue(parsed["currentFollowUp"] is NSNull)

        let item = try XCTUnwrap(parsed["item"] as? [String: Any])
        XCTAssertEqual(Set(item.keys), ["title", "text"])
        XCTAssertEqual(item["title"] as? String, "The Title")
        XCTAssertEqual(item["text"] as? String, "The body text.")

        let map = try XCTUnwrap(parsed["listeningMap"] as? [String: Any])
        XCTAssertEqual(Set(map.keys), ["overview", "chapters"])
        XCTAssertEqual(map["overview"] as? String, "The overview.")
        let listed = try XCTUnwrap(map["chapters"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed[0].keys), ["title", "startChar", "endChar"])
        XCTAssertEqual(listed[0]["title"] as? String, "Opening")
        XCTAssertEqual(listed[0]["startChar"] as? Int, 0)
        XCTAssertEqual(listed[0]["endChar"] as? Int, 120)
        XCTAssertEqual(listed[1]["title"] as? String, "Middle")
        XCTAssertEqual(listed[1]["startChar"] as? Int, 120)
        XCTAssertEqual(listed[1]["endChar"] as? Int, 400)
    }

    func testConversationContextHasTheV2SchemaAndAPrimaryIntent() throws {
        let note = margin("a", cleaned: "A note.")
        let parsed = try context(interjections: [note], followUp: "What did they mean?", explicit: "What did they mean?", primary: [note])

        XCTAssertEqual(parsed["schemaVersion"] as? String, "conversation-context.v2")
        XCTAssertEqual(parsed["currentFollowUp"] as? String, "What did they mean?")
        let intent = try XCTUnwrap(parsed["primaryUserIntent"] as? [String: Any])
        XCTAssertEqual(Set(intent.keys), ["source", "request", "targetType", "target", "interjections"])
        XCTAssertEqual(intent["source"] as? String, "typed_follow_up")
        XCTAssertEqual(intent["request"] as? String, "What did they mean?")
        XCTAssertEqual(intent["targetType"] as? String, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual((intent["interjections"] as? [[String: Any]])?.count, 1)
    }

    func testTheIntentSourceFollowsTheExplicitFollowUpAndThePrimaryMargins() throws {
        let note = margin("a", cleaned: "A note.")
        func source(explicit: String?, primary: [Interjection]) throws -> String? {
            let parsed = try context(followUp: "Continue.", explicit: explicit, primary: primary)
            return (parsed["primaryUserIntent"] as? [String: Any])?["source"] as? String
        }

        XCTAssertEqual(try source(explicit: "Typed.", primary: [note]), "typed_follow_up")
        XCTAssertEqual(try source(explicit: nil, primary: [note]), "target_interjections")
        XCTAssertEqual(try source(explicit: "  \n", primary: [note]), "target_interjections")
        XCTAssertEqual(try source(explicit: nil, primary: []), "conversation_continuation")
    }

    func testAMarginRecordHasFiveKeysAndTheTranscriptFallsBackToPending() throws {
        let cleaned = margin("a", cleaned: "Cleaned.", transcript: "Raw.", display: "Shown.", before: "B1", after: "A1")
        let raw = margin("b", transcript: "Raw only.", display: "Shown.")
        let none = margin("c", display: "Shown, but never sent.", status: "pending")
        let summaryTurn = margin("d", .summaryTurn, target: "t-1", cleaned: "On a summary.")

        let parsed = try context(interjections: [cleaned, raw, none, summaryTurn])

        let records = try XCTUnwrap(parsed["interjections"] as? [[String: Any]])
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records[0].keys), ["targetType", "anchorBefore", "anchorAfter", "transcriptionStatus", "transcript"])
        XCTAssertEqual(records[0]["transcript"] as? String, "Cleaned.")
        XCTAssertEqual(records[0]["anchorBefore"] as? String, "B1")
        XCTAssertEqual(records[0]["anchorAfter"] as? String, "A1")
        XCTAssertEqual(records[0]["targetType"] as? String, "item")
        XCTAssertEqual(records[0]["transcriptionStatus"] as? String, "transcribed")
        XCTAssertEqual(records[1]["transcript"] as? String, "Raw only.")
        XCTAssertEqual(records[2]["transcript"] as? String, "pending", "the display text is not a transcript")
        XCTAssertEqual(records[2]["transcriptionStatus"] as? String, "pending")
        XCTAssertEqual(records[3]["targetType"] as? String, "summary_turn")
    }

    func testThePrimaryMarginsUseTheSameRecordShapeAsTheListedMargins() throws {
        let note = margin("a", transcript: "Raw.", before: "B", after: "A")

        let parsed = try context(interjections: [note], followUp: "Go.", primary: [note])

        let intent = try XCTUnwrap(parsed["primaryUserIntent"] as? [String: Any])
        let primary = try XCTUnwrap(intent["interjections"] as? [[String: Any]])
        let listed = try XCTUnwrap(parsed["interjections"] as? [[String: Any]])
        XCTAssertEqual(NSArray(array: primary), NSArray(array: listed))
    }

    func testRecentTurnsKeepTheLastSixOldestFirst() throws {
        let turns = (1...8).map { turn("t-\($0)", text: "text \($0)") }

        let parsed = try context(turns: turns)

        let recent = try XCTUnwrap(parsed["recentTurns"] as? [[String: Any]])
        XCTAssertEqual(recent.map { $0["text"] as? String }, ["text 3", "text 4", "text 5", "text 6", "text 7", "text 8"])
        XCTAssertEqual(Set(recent[0].keys), ["role", "turnType", "text"])
    }

    func testRecentTurnTextFallsBackFromSummaryToTextToRawTextToEmpty() throws {
        let turns = [
            turn("t-1", summary: "summary", text: "text", raw: "raw"),
            turn("t-2", summary: nil, text: "text", raw: "raw"),
            turn("t-3", summary: nil, text: nil, raw: "raw"),
            turn("t-4", summary: nil, text: nil, raw: nil),
            turn("t-5", summary: "", text: "text", raw: "raw")
        ]

        let parsed = try context(turns: turns)

        let recent = try XCTUnwrap(parsed["recentTurns"] as? [[String: Any]])
        XCTAssertEqual(
            recent.map { $0["text"] as? String },
            ["summary", "text", "raw", "", ""],
            "an empty summary still wins over the text, as it does today"
        )
    }

    func testAShortConversationSendsEveryTurnAndNoneWhenThereAreNone() throws {
        XCTAssertEqual((try context(turns: [])["recentTurns"] as? [Any])?.count, 0)
        XCTAssertEqual((try context(turns: [turn("t-1", text: "one")])["recentTurns"] as? [Any])?.count, 1)
    }

    func testTheContextIsPrettyPrintedWithKeysInSortedOrder() {
        let json = DiscussionContext.contextJSON(
            itemTitle: "T", itemText: "B", overview: "O", chapters: [], turns: [],
            currentTargetType: TargetType.itemTextTTS.rawValue, currentTargetId: nil,
            interjections: [], currentFollowUp: nil
        )

        XCTAssertTrue(json.contains("\n  \"item\""), "pretty-printed over several lines")
        let order = ["currentFollowUp", "interjections", "item", "listeningMap", "primaryUserIntent", "recentTurns", "schemaVersion"]
        let positions = order.compactMap { key in json.range(of: "\"\(key)\"")?.lowerBound }
        XCTAssertEqual(positions.count, order.count)
        XCTAssertEqual(positions, positions.sorted())
    }

    // MARK: - Target context

    func testTheTargetIsTheTurnOnlyForSummaryAndAssistantTargets() throws {
        let turns = [
            turn("t-sum", role: "assistant", type: "interjection_summary", summary: "A summary.", text: "Summary text.", raw: "Summary raw."),
            turn("t-ai", role: "assistant", type: "assistant_response", summary: nil, text: nil, raw: "Response raw.")
        ]

        let summary = DiscussionContext.targetContext(
            currentTargetType: TargetType.summaryTurnTTS.rawValue, currentTargetId: "t-sum",
            turns: turns, itemTitle: "The Title", overview: "The overview.")
        XCTAssertEqual(Set(summary.keys), ["targetType", "role", "turnType", "summary", "text"])
        XCTAssertEqual(summary["targetType"] as? String, "summary_turn_tts")
        XCTAssertEqual(summary["role"] as? String, "assistant")
        XCTAssertEqual(summary["turnType"] as? String, "interjection_summary")
        XCTAssertEqual(summary["summary"] as? String, "A summary.")
        XCTAssertEqual(summary["text"] as? String, "Summary text.")

        let response = DiscussionContext.targetContext(
            currentTargetType: TargetType.assistantTurnTTS.rawValue, currentTargetId: "t-ai",
            turns: turns, itemTitle: "The Title", overview: "The overview.")
        XCTAssertEqual(response["targetType"] as? String, "assistant_turn_tts")
        XCTAssertEqual(response["summary"] as? String, "", "a missing summary is an empty string")
        XCTAssertEqual(response["text"] as? String, "Response raw.", "the raw text stands in for a missing text")
    }

    func testTheTargetFallsBackToTheItemWhenNoTurnMatches() {
        let turns = [turn("t-ai", text: "A response.")]
        let cases: [(String, String?)] = [
            (TargetType.assistantTurnTTS.rawValue, "no-such-turn"),
            (TargetType.assistantTurnTTS.rawValue, nil),
            (TargetType.summaryTurnTTS.rawValue, "t-ai-but-not-a-summary-id"),
            (TargetType.itemTextTTS.rawValue, "t-ai"),
            (TargetType.transcriptBackedMedia.rawValue, "t-ai"),
            ("an_unknown_target", "t-ai")
        ]
        for (type, id) in cases {
            let target = DiscussionContext.targetContext(
                currentTargetType: type, currentTargetId: id, turns: turns, itemTitle: "The Title", overview: "The overview.")
            XCTAssertEqual(Set(target.keys), ["targetType", "title", "overview"], "\(type) \(String(describing: id))")
            XCTAssertEqual(target["targetType"] as? String, "item_text_tts", "\(type) \(String(describing: id))")
            XCTAssertEqual(target["title"] as? String, "The Title")
            XCTAssertEqual(target["overview"] as? String, "The overview.")
        }
    }

    func testTheIntentNamesTheTurnWhenAResponseIsPlaying() throws {
        let turns = [turn("t-ai", summary: "Short.", text: "Long answer.")]

        let parsed = try context(
            turns: turns, targetType: TargetType.assistantTurnTTS.rawValue, targetId: "t-ai", followUp: "Why?")

        let intent = try XCTUnwrap(parsed["primaryUserIntent"] as? [String: Any])
        XCTAssertEqual(intent["targetType"] as? String, "assistant_turn_tts")
        let target = try XCTUnwrap(intent["target"] as? [String: Any])
        XCTAssertEqual(target["text"] as? String, "Long answer.")
        XCTAssertEqual(target["summary"] as? String, "Short.")
    }

    func testTheIntentKeepsTheCallersTargetTypeEvenWhenTheTargetFallsBackToTheItem() throws {
        let parsed = try context(targetType: "an_unknown_target", targetId: "x", followUp: "Why?")

        let intent = try XCTUnwrap(parsed["primaryUserIntent"] as? [String: Any])
        XCTAssertEqual(intent["targetType"] as? String, "an_unknown_target")
        XCTAssertEqual((intent["target"] as? [String: Any])?["targetType"] as? String, "item_text_tts")
    }

    // MARK: - Which Margins, and what is asked

    func testTheCurrentTargetsMarginsAreChosenByTargetTypeAndId() {
        let itemNote = margin("item", .item, target: "item-1")
        let otherItemNote = margin("other-item", .item, target: "item-2")
        let summaryNote = margin("sum", .summaryTurn, target: "t-sum")
        let responseNote = margin("ai", .assistantTurn, target: "t-ai")
        let all = [itemNote, otherItemNote, summaryNote, responseNote]

        func ids(_ type: String, _ id: String?) -> [String] {
            DiscussionContext.currentTargetInterjections(
                interjections: all, currentTargetType: type, currentTargetId: id, itemId: "item-1").map(\.id)
        }

        XCTAssertEqual(ids(TargetType.summaryTurnTTS.rawValue, "t-sum"), ["sum"])
        XCTAssertEqual(ids(TargetType.summaryTurnTTS.rawValue, "t-ai"), [])
        XCTAssertEqual(ids(TargetType.assistantTurnTTS.rawValue, "t-ai"), ["ai"])
        XCTAssertEqual(ids(TargetType.assistantTurnTTS.rawValue, nil), [])
        XCTAssertEqual(ids(TargetType.itemTextTTS.rawValue, "item-1"), ["item"], "the item's Margins are chosen by item id")
        XCTAssertEqual(ids("an_unknown_target", nil), ["item"])
    }

    func testTheRequestIsTheTypedFollowUpTrimmedWhenThereIsOne() {
        XCTAssertEqual(
            DiscussionContext.primaryRequest(explicitFollowUp: "  Answer this.\n", currentInterjections: [margin("a", cleaned: "A note.")]),
            "Answer this."
        )
    }

    func testTheRequestListsTheMarginsTranscriptsWhenNothingWasTyped() {
        let notes = [
            margin("a", cleaned: "  Cleaned first.  ", transcript: "Raw.", display: "Shown."),
            margin("b", transcript: "Raw second."),
            margin("c", display: "Shown third."),
            margin("d", cleaned: "   ")
        ]

        XCTAssertEqual(
            DiscussionContext.primaryRequest(explicitFollowUp: " \n", currentInterjections: notes),
            """
            Respond to the current conversation change expressed in these interjections.
            - Cleaned first.
            - Raw second.
            - Shown third.
            """
        )
    }

    func testTheRequestContinuesTheDiscussionWhenThereIsNothingToSay() {
        let expected = "Continue the discussion from the latest change in the conversation."

        XCTAssertEqual(DiscussionContext.primaryRequest(explicitFollowUp: "", currentInterjections: []), expected)
        XCTAssertEqual(
            DiscussionContext.primaryRequest(explicitFollowUp: "", currentInterjections: [margin("a"), margin("b", cleaned: "  ")]),
            expected,
            "Margins with no words count as nothing"
        )
    }

    func testTheIntentSourceNamesWhereTheRequestCameFrom() {
        let note = margin("a", cleaned: "A note.")

        XCTAssertEqual(DiscussionContext.primaryIntentSource(explicitFollowUp: "Typed.", currentInterjections: []), "typed_follow_up")
        XCTAssertEqual(DiscussionContext.primaryIntentSource(explicitFollowUp: " ", currentInterjections: [note]), "target_interjections")
        XCTAssertEqual(DiscussionContext.primaryIntentSource(explicitFollowUp: "", currentInterjections: []), "conversation_continuation")
    }
}
