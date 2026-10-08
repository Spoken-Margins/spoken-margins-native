import XCTest
@testable import SessionKit

/// #998: reading the provider's reply to the assistant-chapter prompt. This reader throws on a
/// bad chapter; `SessionEngine.extractAssistantChapters` is a different reader that drops it.
final class AssistantChapterParserTests: XCTestCase {
    private func reply(
        schema: String = "assistant-response-map.v1",
        _ chapters: [(id: String, title: String, anchor: String)]
    ) -> String {
        let items = chapters.map { #"{"id":"\#($0.id)","title":"\#($0.title)","anchor":"\#($0.anchor)"}"# }
        return #"{"schemaVersion":"\#(schema)","chapters":[\#(items.joined(separator: ","))]}"#
    }

    private func assertThrows(_ raw: String, _ response: String, _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try AssistantChapterParser.chapters(from: raw, responseText: response), line: line) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed(message), line: line)
            // The model stores "unavailable:<description>" for the listener's diagnostics.
            XCTAssertEqual(error.localizedDescription, "persistence_failed:\(message)", line: line)
        }
    }

    func testAGoodReplyBecomesChaptersAnchoredInTheResponse() throws {
        let response = "Opening words here. Middle part follows. Closing part ends it."
        let chapters = try AssistantChapterParser.chapters(from: reply([
            (id: "ch-1", title: "Opening", anchor: "Opening words"),
            (id: "ch-2", title: "Middle", anchor: "Middle part"),
            (id: "ch-3", title: "Closing", anchor: "Closing part")
        ]), responseText: response)
        XCTAssertEqual(chapters, [
            Chapter(id: "ch-1", title: "Opening", startChar: 0, endChar: 13, percent: 0),
            Chapter(id: "ch-2", title: "Middle", startChar: 20, endChar: 31, percent: 32),
            Chapter(id: "ch-3", title: "Closing", startChar: 41, endChar: 53, percent: 66)
        ])
    }

    func testAReplyWithNoChaptersGivesNone() throws {
        XCTAssertEqual(try AssistantChapterParser.chapters(from: reply([]), responseText: "A short answer."), [])
    }

    func testAnUnknownSchemaVersionIsRejectedBeforeAnyChapterIsRead() {
        assertThrows(reply(schema: "assistant-response-map.v2", [(id: "ch-1", title: "T", anchor: "Opening")]), "Opening words.", "assistant_chapter_schema")
        // The schema check comes first: an unusable chapter under the wrong schema reports the schema.
        assertThrows(reply(schema: "listening-map.v1", [(id: "", title: "", anchor: "nowhere")]), "Opening words.", "assistant_chapter_schema")
        assertThrows(reply(schema: "", []), "Opening words.", "assistant_chapter_schema")
    }

    func testABadChapterRejectsTheWholeReply() {
        let response = "Opening words. Middle part."
        let good = (id: "ch-1", title: "Opening", anchor: "Opening words")
        assertThrows(reply([good, (id: "ch-1", title: "Again", anchor: "Middle part")]), response, "assistant_chapter_anchor") // duplicate id
        assertThrows(reply([good, (id: "", title: "Middle", anchor: "Middle part")]), response, "assistant_chapter_anchor") // empty id
        assertThrows(reply([good, (id: "ch-2", title: "", anchor: "Middle part")]), response, "assistant_chapter_anchor") // empty title
        assertThrows(reply([good, (id: "ch-2", title: "Middle", anchor: "not in the response")]), response, "assistant_chapter_anchor")
        assertThrows(reply([good, (id: "ch-2", title: "Middle", anchor: "")]), response, "assistant_chapter_anchor") // empty anchor
        assertThrows(reply([good, (id: "ch-2", title: "Middle", anchor: "opening words")]), response, "assistant_chapter_anchor") // case differs
    }

    func testAReplyThatIsNotTheEnvelopeIsADecodingFailure() {
        for raw in ["not json", "", #"{"schemaVersion":"assistant-response-map.v1"}"#, #"{"chapters":[]}"#, "[]"] {
            XCTAssertThrowsError(try AssistantChapterParser.chapters(from: raw, responseText: "Opening words.")) { error in
                XCTAssertTrue(error is DecodingError, "\(raw): \(error)")
            }
        }
        // Fields the reader does not know are ignored.
        XCTAssertNoThrow(try AssistantChapterParser.chapters(
            from: #"{"schemaVersion":"assistant-response-map.v1","note":1,"chapters":[{"id":"a","title":"T","anchor":"Opening","description":"x"}]}"#,
            responseText: "Opening words."
        ))
    }

    func testOffsetsCountCharactersNotBytes() throws {
        // Precomposed accents, a family emoji joined by zero-width joiners, and a decomposed
        // accent are each one Character; in UTF-8 they are 2, 18 and 3 bytes.
        let response = "Caf\u{E9} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} r\u{E9}sum\u{E9}. re\u{301}sume\u{301}. Next part."
        let chapters = try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "Next", anchor: "Next part.")]), responseText: response)
        let before = "Caf\u{E9} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} r\u{E9}sum\u{E9}. re\u{301}sume\u{301}. "
        XCTAssertEqual(before.count, 23)
        XCTAssertEqual(chapters.first?.startChar, 23)
        XCTAssertEqual(chapters.first?.endChar, 33)
        XCTAssertGreaterThan(before.utf8.count, 23 + 20, "in bytes the same text is much longer")

        // A carriage return and line feed together are one Character.
        let crlf = try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "Next", anchor: "Next")]), responseText: "line\r\nNext")
        XCTAssertEqual(crlf.first?.startChar, 5)
        XCTAssertEqual(crlf.first?.endChar, 9)
    }

    func testThePercentIsRoundedNotCut() throws {
        // Two of three characters in is 66.67%: rounded to 67, where cutting gives 66.
        let chapters = try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "End", anchor: "c")]), responseText: "abc")
        XCTAssertEqual(chapters.first?.startChar, 2)
        XCTAssertEqual(chapters.first?.percent, 67)
        // One of three is 33.33%, and half way is 50%.
        XCTAssertEqual(try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "B", anchor: "b")]), responseText: "abc").first?.percent, 33)
        XCTAssertEqual(try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "C", anchor: "cd")]), responseText: "abcd").first?.percent, 50)
        // The share counts Characters too: three accented letters then "c" is 3 of 4, not 3 of 7 bytes.
        let accented = "\u{E9}\u{E9}\u{E9}c"
        XCTAssertEqual(try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "C", anchor: "c")]), responseText: accented).first?.percent, 75)
        // 1 of 8 is 12.5%, which rounds away from zero to 13.
        XCTAssertEqual(try AssistantChapterParser.chapters(from: reply([(id: "ch-1", title: "B", anchor: "b")]), responseText: "abcdefgh").first?.percent, 13)
    }

    func testTheFirstMatchOfAnAnchorIsUsed() throws {
        let chapters = try AssistantChapterParser.chapters(
            from: reply([(id: "ch-1", title: "Again", anchor: "again")]),
            responseText: "Say again. And again."
        )
        XCTAssertEqual(chapters.first?.startChar, 4)
        XCTAssertEqual(chapters.first?.endChar, 9)
    }
}
