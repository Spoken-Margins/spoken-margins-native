import XCTest
@testable import SessionKit

/// The parser that turns a pasted (or provider-written) Listening Map JSON into a `ListeningMap`. It moved out of
/// `Gate1AppModel`, where nothing tested it, so these tests pin what it did when it moved. They avoid inputs whose
/// result depends on the platform's Foundation (number bridging, `JSONSerialization` error text).
final class ManualListeningMapParserTests: XCTestCase {
    private let text = "The harbor town woke before dawn. Fishermen hauled nets across the quay while gulls circled overhead. "
        + "By noon the market—crowded and loud—was full of buyers haggling over mackerel and cod. "
        + "In the evening the lighthouse keeper climbed the spiral stairs and lit the great lamp."

    private func item(text: String? = nil, id: String = "item-1") -> Item {
        Item(id: id, title: "Harbor", mediaType: "text", text: text ?? self.text, externalReference: nil, status: "ready")
    }

    private func map(_ chapters: String, overview: String = "A day at the harbor.", schema: String = "listening-map.v1") -> String {
        """
        {"schemaVersion": "\(schema)", "overview": "\(overview)", "chapters": [\(chapters)]}
        """
    }

    private func chapter(_ id: String, anchor: String, title: String = "Title", description: String = "About it") -> String {
        """
        {"id": "\(id)", "title": "\(title)", "description": "\(description)", "anchor": "\(anchor)"}
        """
    }

    /// Character offset of the first occurrence of `phrase` in the item text.
    private func offset(of phrase: String, end: Bool = false) throws -> Int {
        let range = try XCTUnwrap(text.range(of: phrase), "\(phrase) is not in the test text")
        return text.distance(from: text.startIndex, to: end ? range.upperBound : range.lowerBound)
    }

    private func failure(_ raw: String, item: Item? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try ManualListeningMapParser.parse(raw, item: item ?? self.item())
            XCTFail("expected a failure", file: file, line: line)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: A well-formed map

    func testAMapPlacesChaptersByAnchorAndSortsThemByPosition() throws {
        let raw = map([
            chapter("ch-2", anchor: "By noon the market", title: "  Midday  "),
            chapter("ch-1", anchor: "The harbor town woke before dawn."),
            chapter("ch-3", anchor: "In the evening the lighthouse keeper")
        ].joined(separator: ","), overview: "  A day at the harbor.  ")
        let parsed = try ManualListeningMapParser.parse(raw, item: item())

        XCTAssertEqual(parsed.id, "map-item-1-manual")
        XCTAssertEqual(parsed.itemId, "item-1")
        XCTAssertEqual(parsed.overview, "A day at the harbor.")
        XCTAssertEqual(parsed.chapters.map(\.id), ["ch-1", "ch-2", "ch-3"])
        XCTAssertEqual(parsed.chapters.map(\.title), ["Title", "Midday", "Title"])
        XCTAssertEqual(parsed.chapters[0].startChar, 0)
        XCTAssertEqual(parsed.chapters[0].endChar, try offset(of: "The harbor town woke before dawn.", end: true))
        XCTAssertEqual(parsed.chapters[1].startChar, try offset(of: "By noon the market"))
        XCTAssertEqual(parsed.chapters[2].startChar, try offset(of: "In the evening the lighthouse keeper"))
        let count = Double(text.count)
        XCTAssertEqual(parsed.chapters.map(\.percent), parsed.chapters.map { Int(Double($0.startChar) / count * 100) })
        XCTAssertEqual(parsed.chapters[0].percent, 0)
    }

    func testChaptersAtTheSamePositionSortById() throws {
        let raw = map([
            chapter("b", anchor: "The harbor town woke"),
            chapter("a", anchor: "The harbor town woke before dawn.")
        ].joined(separator: ","))
        XCTAssertEqual(try ManualListeningMapParser.parse(raw, item: item()).chapters.map(\.id), ["a", "b"])
    }

    func testAChapterCanCarryCharacterOffsetsInsteadOfAnAnchor() throws {
        let raw = map("""
        {"id": "ch-1", "title": "Opening", "description": "The start", "startChar": 10, "endChar": 40}
        """)
        let chapters = try ManualListeningMapParser.parse(raw, item: item()).chapters
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].startChar, 10)
        XCTAssertEqual(chapters[0].endChar, 40)
        XCTAssertEqual(chapters[0].percent, Int(10.0 / Double(text.count) * 100))
    }

    func testAnchorTextIsAcceptedWhereAnchorIsMissing() throws {
        let raw = map("""
        {"id": "ch-1", "title": "Opening", "description": "The start", "anchorText": "Fishermen hauled nets"}
        """)
        XCTAssertEqual(try ManualListeningMapParser.parse(raw, item: item()).chapters[0].startChar, try offset(of: "Fishermen hauled nets"))
    }

    // MARK: Finding an anchor

    func testAnchorsMatchIgnoringCaseAndDiacritics() throws {
        let source = "We met at the Café Münster before the long walk home along the river."
        let raw = map(chapter("ch-1", anchor: "cafe munster before"))
        let chapters = try ManualListeningMapParser.parse(raw, item: item(text: source)).chapters
        let range = try XCTUnwrap(source.range(of: "Café Münster before"))
        XCTAssertEqual(chapters[0].startChar, source.distance(from: source.startIndex, to: range.lowerBound))
        XCTAssertEqual(chapters[0].endChar, source.distance(from: source.startIndex, to: range.upperBound))
    }

    func testAnchorsMatchIgnoringPunctuationAndMapBackToTheOriginalText() throws {
        // The source has em dashes where the anchor has spaces.
        let raw = map(chapter("ch-1", anchor: "market crowded and loud was full"))
        let chapters = try ManualListeningMapParser.parse(raw, item: item()).chapters
        XCTAssertEqual(chapters[0].startChar, try offset(of: "market"))
        XCTAssertEqual(chapters[0].endChar, try offset(of: "was full", end: true))
    }

    func testALongAnchorWithAWrongTailFallsBackToItsLongestMatchingRun() throws {
        let raw = map(chapter("ch-1", anchor: "the evening lighthouse keeper climbed the spiral stairs and then walked off into the sea"))
        let chapters = try ManualListeningMapParser.parse(raw, item: item()).chapters
        // The longest run of the anchor's words that the text has, scanning from the start of the anchor.
        XCTAssertEqual(chapters[0].startChar, try offset(of: "lighthouse keeper climbed the spiral stairs and"))
        XCTAssertEqual(chapters[0].endChar, try offset(of: "lighthouse keeper climbed the spiral stairs and", end: true))
    }

    func testAShortAnchorThatIsNotInTheTextIsRejected() {
        XCTAssertEqual(failure(map(chapter("ch-9", anchor: "not in the text"))), "manual_map_anchor_not_found:ch-9")
    }

    // MARK: Failures

    func testEachFailureNamesItselfInTheWordsTheRepairPromptShowsTheModel() {
        let anchored = chapter("ch-1", anchor: "The harbor town woke")
        XCTAssertEqual(failure("   \n "), "manual_map_empty")
        XCTAssertEqual(failure("[1, 2]"), "manual_map_root_must_be_object")
        XCTAssertEqual(failure(map(anchored, schema: "listening-map.v2")), "manual_map_schemaVersion_must_be_listening-map.v1")
        XCTAssertEqual(failure(map(anchored, overview: "  ")), "manual_map_missing_overview")
        XCTAssertEqual(failure(map("")), "manual_map_missing_chapters")
        XCTAssertEqual(failure(map(anchored), item: item(text: "")), "manual_map_item_has_no_text")
        XCTAssertEqual(failure(map(#"{"title": "T", "description": "D", "anchor": "The harbor town woke"}"#)), "manual_map_missing_chapter_id")
        XCTAssertEqual(failure(map([anchored, anchored].joined(separator: ","))), "manual_map_duplicate_chapter_id:ch-1")
        XCTAssertEqual(failure(map(#"{"id": "c", "title": " ", "description": "D", "anchor": "The harbor town woke"}"#)), "manual_map_missing_chapter_title:c")
        XCTAssertEqual(failure(map(#"{"id": "c", "title": "T", "anchor": "The harbor town woke"}"#)), "manual_map_missing_chapter_description:c")
        XCTAssertEqual(failure(map(#"{"id": "c", "title": "T", "description": "D"}"#)), "manual_map_missing_chapter_anchor:c")
        XCTAssertEqual(failure(map(#"{"id": "c", "title": "T", "description": "D", "anchor": "  "}"#)), "manual_map_missing_chapter_anchor:c")
    }

    func testMalformedJSONFailsWithTheParserMessageAfterTheFixedPrefix() throws {
        let message = try XCTUnwrap(failure("{this is not json}"))
        XCTAssertTrue(message.hasPrefix("manual_map_json_parse_failed:"), message)
    }

    func testOffsetsOutsideTheTextAreRejected() {
        func offsets(_ start: Int, _ end: Int) -> String {
            map(#"{"id": "c", "title": "T", "description": "D", "startChar": \#(start), "endChar": \#(end)}"#)
        }
        XCTAssertEqual(failure(offsets(-1, 5)), "manual_map_invalid_chapter_range:c")
        XCTAssertEqual(failure(offsets(5, 5)), "manual_map_invalid_chapter_range:c")
        XCTAssertEqual(failure(offsets(5, 3)), "manual_map_invalid_chapter_range:c")
        XCTAssertEqual(failure(offsets(0, text.count + 1)), "manual_map_invalid_chapter_range:c")
    }

    func testTheErrorDescriptionsAreStable() {
        let descriptions: [(ManualListeningMapError, String)] = [
            (.empty, "manual_map_empty"),
            (.invalidUTF8, "manual_map_invalid_utf8"),
            (.rootMustBeObject, "manual_map_root_must_be_object"),
            (.invalidSchema, "manual_map_schemaVersion_must_be_listening-map.v1"),
            (.missingOverview, "manual_map_missing_overview"),
            (.missingChapters, "manual_map_missing_chapters"),
            (.itemHasNoText, "manual_map_item_has_no_text"),
            (.missingChapterId, "manual_map_missing_chapter_id"),
            (.duplicateChapterId("x"), "manual_map_duplicate_chapter_id:x"),
            (.missingChapterTitle("x"), "manual_map_missing_chapter_title:x"),
            (.missingChapterDescription("x"), "manual_map_missing_chapter_description:x"),
            (.missingChapterAnchor("x"), "manual_map_missing_chapter_anchor:x"),
            (.anchorNotFound("x"), "manual_map_anchor_not_found:x"),
            (.invalidChapterRange("x"), "manual_map_invalid_chapter_range:x"),
            (.jsonParseFailed("boom"), "manual_map_json_parse_failed:boom")
        ]
        for (error, expected) in descriptions {
            XCTAssertEqual(String(describing: error), expected)
        }
    }

    // MARK: Repairing the JSON text

    private func repaired(_ raw: String) -> String {
        ManualListeningMapParser.repairedJSONObjectString(from: raw)
    }

    private func repairedObject(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(repaired(raw).data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    func testAMarkdownFenceAndTextAroundTheObjectAreDropped() {
        XCTAssertEqual(repaired("```json\n{\"a\": 1}\n```"), "{\"a\": 1}")
        XCTAssertEqual(repaired("```\n{\"a\": 1}\n```  "), "{\"a\": 1}")
        XCTAssertEqual(repaired("Here is the map: {\"a\": 1} Hope that helps!"), "{\"a\": 1}")
    }

    func testCurlyQuotesInsideStringValuesAreLeftAlone() {
        let inside = "{\"a\": \"it’s “fine”\"}"
        XCTAssertEqual(repaired(inside), inside)
    }

    func testJSONDelimitedOnlyByCurlyQuotesParses() throws {
        // #949: pasted from a document editor or written by a model that ignored the straight-quote instruction.
        let raw = "{“schemaVersion”: “listening-map.v1”, “overview”: “A day.”, “chapters”: [{“id”: “c1”, “title”: “T”, “description”: “D”, “anchor”: “any phrase from the text”}]}"
        let object = try repairedObject(raw)
        XCTAssertEqual(object["schemaVersion"] as? String, "listening-map.v1")
        XCTAssertEqual(object["overview"] as? String, "A day.")
        let chapter = try XCTUnwrap((object["chapters"] as? [[String: Any]])?.first)
        XCTAssertEqual(chapter["anchor"] as? String, "any phrase from the text")
    }

    /// Neighbouring inputs for the curly-quote rule: each row is the text a listener could paste and the
    /// value the key "a" must hold afterwards.
    func testCurlyQuoteRepairTable() throws {
        let rows: [(name: String, raw: String, expected: String)] = [
            ("curly both ends", "{“a”: “x”}", "x"),
            ("curly opener, straight closer", "{“a\": “x\"}", "x"),
            ("plain straight quotes are untouched", "{\"a\": \"x\"}", "x"),
            ("right curly quote used as the opener", "{”a”: ”x”}", "x"),
            ("empty string", "{“a”: ””}", ""),
            ("whitespace before the comma", "{“a”: “x”   , “b”: “y”}", "x"),
            ("newline before the closing brace", "{“a”: “x”\n}", "x"),
            ("curly opener, straight closer, curly quotes and a comma inside", "{“a\": “He called it “great”, then left\"}", "He called it “great”, then left"),
            ("curly quotes inside the text", "{“a”: “she said “hi” twice”}", "she said “hi” twice"),
            ("an apostrophe inside the text", "{“a”: “it’s fine”}", "it’s fine"),
            ("a straight quote inside the text", "{“a”: “6\" ruler”}", "6\" ruler"),
            ("an escaped quote inside the text", "{“a”: “say \\\"hi\\\"”}", "say \"hi\""),
            ("a colon inside the text", "{“a”: “note: this, that”}", "note: this, that"),
            ("a list of curly strings", "{“a”: “x”, “b”: [“p”, “q”]}", "x"),
            ("Unicode text", "{“a”: “日本語 “ok””}", "日本語 “ok”"),
        ]
        for row in rows {
            guard let data = repaired(row.raw).data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                XCTFail("\(row.name): \(repaired(row.raw)) does not parse")
                continue
            }
            XCTAssertEqual(object["a"] as? String, row.expected, row.name)
        }
        let list = try repairedObject("{“a”: “x”, “b”: [“p”, “q”]}")
        XCTAssertEqual(list["b"] as? [String], ["p", "q"])
    }

    func testAnUnclosedCurlyStringStillFailsToParseInsteadOfSwallowingTheRest() {
        XCTAssertThrowsError(try ManualListeningMapParser.parse("{“schemaVersion”: “listening-map.v1", item: item()))
    }

    func testCommentsAreRemovedExceptInsideStrings() throws {
        let object = try repairedObject("""
        {"a": "x", // a note
         "b": /* inline */ "http://example.com/a", /* the
         rest */ "c": "y"}
        """)
        XCTAssertEqual(object["a"] as? String, "x")
        XCTAssertEqual(object["b"] as? String, "http://example.com/a")
        XCTAssertEqual(object["c"] as? String, "y")
    }

    func testRawControlCharactersInsideStringsAreEscaped() throws {
        let object = try repairedObject("{\"a\": \"line one\nline two\ttabbed\r\u{01}\"}")
        XCTAssertEqual(object["a"] as? String, "line one\nline two\ttabbed\r\u{01}")
        XCTAssertTrue(repaired("{\"a\": \"x\ny\"}").contains("\\n"))
        XCTAssertTrue(repaired("{\"a\": \"\u{01}\"}").contains("\\u0001"))
    }

    func testTrailingCommasAreRemoved() throws {
        XCTAssertEqual(repaired("{\"a\": [1, 2,], \"b\": 3,}"), "{\"a\": [1, 2], \"b\": 3}")
    }

    func testAMessyResponseWithEveryProblemStillParses() throws {
        let raw = """
        Sure! Here is your map:
        ```json
        {"schemaVersion": "listening-map.v1", // required
         "overview": "A day at the harbor.",
         "chapters": [
           {"id": "ch-1", "title": "Dawn", "description": "The town
        wakes", "anchor": "Fishermen hauled nets across the quay"},
         ],
        }
        ```
        """
        let chapters = try ManualListeningMapParser.parse(raw, item: item()).chapters
        XCTAssertEqual(chapters.map(\.id), ["ch-1"])
        XCTAssertEqual(chapters[0].startChar, try offset(of: "Fishermen hauled nets across the quay"))
    }
}
