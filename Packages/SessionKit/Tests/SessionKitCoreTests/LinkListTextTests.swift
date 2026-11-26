import XCTest
@testable import SessionKit

/// #4683: a link list inside pasted text (an AI's reply) is found by its marker, and text without the marker is never
/// a list and never refused.
final class LinkListTextTests: XCTestCase {
    private let version = LinkListFile.schemaVersion

    private var json: String {
        """
        {
          "schemaVersion": "\(version)",
          "title": "Morning brief",
          "entries": [
            {"url": "https://example.com/a", "title": "A"},
            {"url": "https://example.com/show", "follow": true}
          ]
        }
        """
    }

    private func found(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> LinkListFile? {
        guard case .linkList(let list) = LinkListText.find(in: text) else {
            XCTFail("Expected a link list in: \(text.prefix(80))", file: file, line: line)
            return nil
        }
        return list
    }

    private func assertList(_ text: String, row: String, file: StaticString = #filePath, line: UInt = #line) {
        let list = found(text, file: file, line: line)
        XCTAssertEqual(list?.title, "Morning brief", "row: \(row)", file: file, line: line)
        XCTAssertEqual(list?.entries.map(\.url), ["https://example.com/a", "https://example.com/show"], "row: \(row)", file: file, line: line)
        XCTAssertEqual(list?.entries.map(\.follow), [false, true], "row: \(row)", file: file, line: line)
    }

    private func assertRefused(_ text: String, row: String, contains: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .rejected(let message) = LinkListText.find(in: text) else {
            return XCTFail("Expected a refusal for row: \(row)", file: file, line: line)
        }
        if let contains { XCTAssertTrue(message.contains(contains), "row: \(row): \(message)", file: file, line: line) }
    }

    // MARK: - Where the block sits

    func testTheBlockIsFoundWithAndWithoutAFenceAndWithProseAroundIt() {
        assertList(json, row: "bare JSON")
        assertList("```json\n\(json)\n```", row: "json fence")
        assertList("```\n\(json)\n```", row: "bare fence")
        assertList("Here is your brief for today:\n\n```json\n\(json)\n```\n\nEnjoy! Tell me what to change.", row: "prose both sides")
        assertList("Sure!\n\(json)", row: "prose before")
        assertList("\(json)\nLet me know.", row: "prose after")
    }

    func testCRLFLineEndingsAndAByteOrderMarkDoNotMatter() {
        assertList(json.replacingOccurrences(of: "\n", with: "\r\n"), row: "CRLF")
        assertList("\u{FEFF}" + json, row: "BOM")
        assertList("\u{FEFF}Here you go:\r\n```json\r\n" + json.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n```", row: "BOM, CRLF, fence")
    }

    func testSmartQuotesAndApostrophesInTheProseAreIgnored() {
        assertList("Here\u{2019}s \u{201C}your\u{201D} brief:\n\(json)\nIt\u{2019}s \"short\".", row: "smart quotes in prose")
        assertList("Don't worry, it's fine. A stray \" quote here.\n\(json)", row: "stray quote before")
    }

    func testBracesInsideAStringValueDoNotEndTheObjectEarly() {
        let text = """
        {"schemaVersion": "\(version)", "title": "Brace } and { and \\" quote",
         "entries": [{"url": "https://example.com/a", "title": "x } y"}]}
        """
        XCTAssertEqual(found(text)?.title, "Brace } and { and \" quote")
        XCTAssertEqual(found(text)?.entries.map(\.url), ["https://example.com/a"])
    }

    func testAStrayBraceInTheProseBeforeTheBlockDoesNotHideIt() {
        assertList("Use {curly braces} as you like, or maybe { alone.\n\(json)", row: "braces in prose")
    }

    func testAStrayQuoteAfterAnUnclosedBraceInTheProseDoesNotHideTheBlock() {
        assertList("I wrote {x and said \"hi\nHere is the block:\n\(json)", row: "stray quote after open brace")
        assertList("Snippet: { a: 'say \"hi' }\n\(json)", row: "quote in an earlier snippet")
        assertList("Open { and a lone quote \"\r\n```json\n\(json)\n```", row: "CRLF after the stray quote")
    }

    func testAnotherFormatsObjectBeforeTheListIsSkipped() {
        let other = #"{"schemaVersion": "somebody-else.v1", "entries": [{"url": "https://example.com/other"}]}"#
        assertList("Another file:\n\(other)\n\nYours:\n\(json)", row: "other schema then list")
        let edition = #"{"schemaVersion": "spoken-margins.listening-edition.v1", "title": "Edition"}"#
        assertList("\(edition)\n\(json)", row: "listening edition then list")
    }

    func testAListInsideAnotherObjectIsFound() {
        assertList(#"{"result": \#(json), "ok": true}"#, row: "wrapped in a result object")
    }

    func testTwoListsTheFirstOneWins() {
        let second = json.replacingOccurrences(of: "Morning brief", with: "Evening brief")
        assertList("\(json)\n\nand another:\n\(second)", row: "two lists")
    }

    func testALaterRefusalNeverBeatsAnEarlierList() {
        let v2 = #"{"schemaVersion": "spoken-margins.link-list.v2", "entries": [{"url": "https://example.com/a"}]}"#
        assertList("\(json)\n\(v2)", row: "list then v2")
        assertList("\(json)\n{\"schemaVersion\": \"\(version)\", \"entries\": [],}", row: "list then broken list")
    }

    func testAnEarlierRefusalLosesToALaterList() {
        let v2 = #"{"schemaVersion": "spoken-margins.link-list.v2", "entries": [{"url": "https://example.com/a"}]}"#
        assertList("\(v2)\n\(json)", row: "v2 then list")
    }

    // MARK: - Refusals

    func testANewerVersionIsRefusedByName() {
        let v2 = #"{"schemaVersion": "spoken-margins.link-list.v2", "entries": [{"url": "https://example.com/a"}]}"#
        assertRefused("```json\n\(v2)\n```", row: "v2", contains: "spoken-margins.link-list.v2")
    }

    func testJSONThatCantBeParsedGivesTheCouldntBeReadMessage() {
        let rows = [
            // A missing comma, single quotes and an unquoted key are invalid JSON on every platform.
            #"{"schemaVersion": "\#(version)", "entries": [{"url": "https://example.com/a"} {"url": "https://example.com/b"}]}"#,
            "{'schemaVersion': '\(version)', 'entries': [{'url': 'https://example.com/a'}]}",
            #"{schemaVersion: "\#(version)", "entries": [{"url": "https://example.com/a"}]}"#,
        ]
        for row in rows {
            XCTAssertEqual(LinkListText.find(in: row), .rejected(LinkListText.unreadableMessage), "row: \(row.prefix(50))")
            XCTAssertEqual(LinkListText.find(in: "Here:\n```json\n\(row)\n```"), .rejected(LinkListText.unreadableMessage),
                           "fenced row: \(row.prefix(50))")
        }
    }

    /// `JSONSerialization` accepts a trailing comma on Linux and refuses it where this was designed (Apple platforms;
    /// not run here). Either way the listener gets a list or the couldn't-be-read message, never a crash or a silent miss.
    func testATrailingCommaIsAListOrTheCouldntBeReadMessageNeverSilentlyIgnored() {
        let text = #"{"schemaVersion": "\#(version)", "entries": [{"url": "https://example.com/a"},]}"#
        switch LinkListText.find(in: text) {
        case .linkList(let list): XCTAssertEqual(list.entries.map(\.url), ["https://example.com/a"])
        case .rejected(let message): XCTAssertEqual(message, LinkListText.unreadableMessage)
        case .notALinkList: XCTFail("A reply that holds the marker must be read or refused")
        }
    }

    func testAReplyCutOffInsideTheObjectGivesTheCouldntBeReadMessage() {
        let cut = String(json.prefix(json.count - 12))
        XCTAssertEqual(LinkListText.find(in: cut), .rejected(LinkListText.unreadableMessage))
    }

    func testSpecificRefusalsFromTheFileRulesCarryThrough() {
        let tooManyFollows = (1...11).map { #"{"url": "https://example.com/\#($0)", "follow": true}"# }.joined(separator: ",")
        assertRefused(#"Here: {"schemaVersion": "\#(version)", "entries": [\#(tooManyFollows)]}"#, row: "11 follows",
                      contains: "more than 10 shows to follow")
        let tooManyEntries = (1...51).map { #"{"url": "https://example.com/\#($0)"}"# }.joined(separator: ",")
        assertRefused(#"{"schemaVersion": "\#(version)", "entries": [\#(tooManyEntries)]}"#, row: "51 entries", contains: "51")
        assertRefused(#"{"schemaVersion": "\#(version)", "entries": []}"#, row: "no entries", contains: "no entries")
    }

    // MARK: - Not a list

    func testTextWithoutTheMarkerIsNeverAListAndNeverRefused() {
        let rows = [
            "",
            "   \n",
            "https://example.com/only-a-url",
            "One link per line:\nhttps://example.com/a\nhttps://example.com/b",
            #"{"schemaVersion": "somebody-else.v1", "entries": [{"url": "https://example.com/a"}]}"#,
            #"{"urls": ["https://example.com/a"]}"#,
            "{ not json https://example.com/a",
            #"{"schemaVersion": "Spoken-Margins.Link-List.v1", "entries": [{"url": "https://example.com/a"}]}"#,
        ]
        for row in rows {
            XCTAssertEqual(LinkListText.find(in: row), .notALinkList, "row: \(row.prefix(50))")
            XCTAssertFalse(LinkListText.mightContain(row), "row: \(row.prefix(50))")
        }
    }

    func testTheMarkerOnlyInProseIsNotAList() {
        let rows = [
            "The format is spoken-margins.link-list.v1, see the docs.",
            "schemaVersion: spoken-margins.link-list.v1\nhttps://example.com/a",
            "Use {curly braces} freely, and the spoken-margins.link-list.v1 format is documented.",
            "{\"a\": 1} then prose naming spoken-margins.link-list.v1",
            "Use { for blocks. The format is spoken-margins.link-list.v1.",
            "Use { and say \"spoken-margins.link-list.v1\" in a sentence.\nNo block here.",
        ]
        for row in rows {
            XCTAssertEqual(LinkListText.find(in: row), .notALinkList, "row: \(row.prefix(50))")
            XCTAssertTrue(LinkListText.mightContain(row), "row: \(row.prefix(50))")
        }
    }

    func testAMarkerFollowedByACombiningMarkIsStillTheMarkForBothChecks() {
        let text = "spoken-margins.link-list.\u{301}v1"
        XCTAssertTrue(LinkListText.mightContain(text))
        let big = text + String(repeating: "a", count: LinkListFile.maxFileBytes)
        XCTAssertEqual(LinkListText.find(in: big), .rejected(LinkListFile.tooLargeMessage))
    }

    func testTheMarkerIsCaseSensitiveLikeTheFileRule() {
        XCTAssertFalse(LinkListText.mightContain("SPOKEN-MARGINS.LINK-LIST.V1"))
        XCTAssertTrue(LinkListText.mightContain(LinkListFile.schemaVersion))
    }

    // MARK: - Size

    /// A list padded with prose (no braces) to exactly `bytes` UTF-8 bytes.
    private func padded(to bytes: Int) -> String {
        let body = json
        let padding = String(repeating: "a", count: bytes - body.utf8.count)
        return body + padding
    }

    func testReplyOfExactlyOneMegabyteArrivesWholeAndOneByteMoreIsRefused() {
        let atLimit = padded(to: LinkListFile.maxFileBytes)
        XCTAssertEqual(atLimit.utf8.count, 1_000_000)
        XCTAssertEqual(found(atLimit)?.entries.count, 2)
        let over = padded(to: LinkListFile.maxFileBytes + 1)
        XCTAssertEqual(LinkListText.find(in: over), .rejected(LinkListFile.tooLargeMessage))
    }

    func testAListObjectThatIsItselfOneMegabyteArrivesWholeAndOneByteMoreIsRefused() {
        func list(bytes: Int) -> String {
            let head = #"{"schemaVersion": "\#(version)", "entries": [{"url": "https://example.com/a", "title": ""#
            let tail = #""}]}"#
            return head + String(repeating: "t", count: bytes - head.utf8.count - tail.utf8.count) + tail
        }
        let exact = list(bytes: 1_000_000)
        XCTAssertEqual(exact.utf8.count, 1_000_000)
        XCTAssertEqual(found(exact)?.entries.count, 1)
        XCTAssertEqual(LinkListText.find(in: list(bytes: 1_000_001)), .rejected(LinkListFile.tooLargeMessage))
    }

    func testAnOversizeReplyWithoutTheMarkerIsNotAListAndIsNotRefused() {
        let big = String(repeating: "a", count: LinkListFile.maxFileBytes + 1)
        XCTAssertEqual(LinkListText.find(in: big), .notALinkList)
        XCTAssertFalse(LinkListText.mightContain(big))
    }

    func testFiftyEntriesArriveWholeAndFiftyOneAreRefused() {
        func reply(_ count: Int) -> String {
            let rows = (1...count).map { #"{"url": "https://example.com/\#($0)"}"# }.joined(separator: ",")
            return "Here:\n```json\n" + #"{"schemaVersion": "\#(version)", "entries": [\#(rows)]}"# + "\n```"
        }
        XCTAssertEqual(found(reply(LinkListFile.maxEntries))?.entries.count, 50)
        assertRefused(reply(LinkListFile.maxEntries + 1), row: "51 entries", contains: "51")
    }

    // MARK: - Cost

    func testManyUnclosedBracesAndManyMarkersFinishQuicklyAndAreRefusedOrIgnored() {
        // The reply is cut off inside a very large pile of braces; nothing here is a list, and nothing is quadratic.
        let braces = String(repeating: "{", count: 400_000)
        XCTAssertEqual(LinkListText.find(in: braces + #""schemaVersion": ""# + LinkListFile.schemaVersion),
                       .rejected(LinkListText.unreadableMessage))
        let markers = String(repeating: LinkListFile.schemaVersion + " ", count: 30_000)
        XCTAssertEqual(LinkListText.find(in: markers), .notALinkList)
        let pairs = String(repeating: "{}", count: 200_000) + "{" + LinkListFile.schemaVersion + "}"
        XCTAssertEqual(LinkListText.find(in: pairs), .rejected(LinkListText.unreadableMessage))
    }

    func testAVeryDeeplyNestedObjectTriesAtMostAFewCandidates() {
        let depth = 5_000
        let nested = String(repeating: #"{"a": "#, count: depth) + "\"\(LinkListFile.schemaVersion)\"" + String(repeating: "}", count: depth)
        // Not a list; the point is that it returns instead of parsing five thousand overlapping objects.
        XCTAssertEqual(LinkListText.find(in: nested), .rejected(LinkListText.unreadableMessage))
    }
}
