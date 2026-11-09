import XCTest
@testable import SessionKit

/// #3767: a structured link list is recognized only by its `schemaVersion`, never by sniffing text.
final class LinkListFileTests: XCTestCase {
    private func recognize(_ json: String) -> LinkListFile.Recognition {
        LinkListFile.recognize(Data(json.utf8))
    }

    private func list(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> LinkListFile? {
        guard case .linkList(let value) = recognize(json) else {
            XCTFail("Expected a link list", file: file, line: line)
            return nil
        }
        return value
    }

    private let version = LinkListFile.schemaVersion

    func testAListWithEveryKindOfLinkKeepsFileOrderAndTitles() {
        let found = list("""
        {"schemaVersion": "\(version)", "title": "Morning brief",
         "entries": [
           {"url": "https://podcasts.apple.com/us/podcast/x/id1?i=2", "title": "An episode"},
           {"url": "https://feeds.example.com/show.xml"},
           {"url": "https://example.com/article", "title": "  An article  "},
           {"url": "https://example.com/paper.pdf"}
         ]}
        """)
        XCTAssertEqual(found?.title, "Morning brief")
        XCTAssertEqual(found?.entries.map(\.url), [
            "https://podcasts.apple.com/us/podcast/x/id1?i=2", "https://feeds.example.com/show.xml",
            "https://example.com/article", "https://example.com/paper.pdf",
        ])
        XCTAssertEqual(found?.entries.map(\.title), ["An episode", nil, "An article", nil])
        XCTAssertEqual(found?.skipped, [])
    }

    func testOneLinkIsAListWithOneEntryAndTitlesAreOptional() {
        let found = list(#"{"schemaVersion": "\#(version)", "entries": [{"url": "https://example.com/a"}]}"#)
        XCTAssertNil(found?.title)
        XCTAssertEqual(found?.entries, [LinkListFile.Entry(url: "https://example.com/a")])
    }

    func testUnknownFieldsAreIgnored() {
        let found = list("""
        {"schemaVersion": "\(version)", "generatedBy": "an assistant", "extra": {"a": 1},
         "entries": [{"url": "https://example.com/a", "note": "later version", "rank": 3}]}
        """)
        XCTAssertEqual(found?.entries.map(\.url), ["https://example.com/a"])
    }

    func testAnUnknownVersionOfTheFormatIsRejectedWithAClearMessage() {
        let result = recognize(#"{"schemaVersion": "spoken-margins.link-list.v2", "entries": [{"url": "https://example.com/a"}]}"#)
        guard case .rejected(let message) = result else { return XCTFail("Expected a rejection, got \(result)") }
        XCTAssertTrue(message.contains("spoken-margins.link-list.v2"))
        XCTAssertTrue(message.contains(version))
    }

    // MARK: - No sniffing: anything that does not announce itself is left alone

    func testTextAndMarkdownContentIsNeverALinkList() {
        let rows = [
            "https://example.com/only-a-url",
            "https://example.com/a\nhttps://example.com/b\nhttps://example.com/c",
            "Read this later: https://example.com/essay and tell me what you think.",
            "# Reading list\n\n- [One](https://example.com/1)\n- [Two](https://example.com/2)\n\nschemaVersion: spoken-margins.link-list.v1\n",
            "",
            "   \n\n",
            "{ not json at all https://example.com/a",
        ]
        for row in rows {
            XCTAssertEqual(LinkListFile.recognize(Data(row.utf8)), .notALinkList, "row: \(row.prefix(40))")
        }
    }

    func testJSONThatIsNotThisFormatIsLeftToTheOtherImports() {
        let rows = [
            "[]",
            #"["https://example.com/a", "https://example.com/b"]"#,
            #"{"entries": [{"url": "https://example.com/a"}]}"#,
            #"{"urls": ["https://example.com/a"]}"#,
            #"{"schemaVersion": 1, "entries": [{"url": "https://example.com/a"}]}"#,
            #"{"schemaVersion": null}"#,
            #"{"schemaVersion": "spoken-margins.listening-edition.v1", "title": "Edition", "sourceURL": "https://example.com/a"}"#,
            #"{"schemaVersion": "somebody-else.v1", "entries": [{"url": "https://example.com/a"}]}"#,
            #"{"schemaVersion": "Spoken-Margins.link-list.v1", "entries": [{"url": "https://example.com/a"}]}"#,
        ]
        for row in rows {
            XCTAssertEqual(recognize(row), .notALinkList, "row: \(row.prefix(60))")
        }
    }

    func testAListeningEditionIsNotARelatedFormat() {
        XCTAssertFalse(ListeningEdition.version.hasPrefix(LinkListFile.schemaFamilyPrefix))
    }

    // MARK: - Entries

    func testOnlyHTTPSLinksWithAHostComeInAndTheRestAreNamed() {
        let found = list("""
        {"schemaVersion": "\(version)", "entries": [
          {"url": "http://example.com/plain-http"},
          {"url": "https://example.com/good"},
          {"url": "ftp://example.com/file"},
          {"url": "javascript:alert(1)"},
          {"url": "https:///no-host"},
          {"url": "example.com/no-scheme"},
          {"url": ""},
          {"title": "no url at all"},
          "https://example.com/bare-string",
          {"url": 7}
        ]}
        """)
        XCTAssertEqual(found?.entries.map(\.url), ["https://example.com/good"])
        XCTAssertEqual(found?.skipped.map(\.position), [1, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(found?.skipped.first?.text, "http://example.com/plain-http")
        XCTAssertEqual(found?.skipped.first?.reason, "is not an https link")
        XCTAssertNil(found?.skipped.last?.text)
    }

    func testUppercaseSchemeAndSurroundingSpaceAreAccepted() {
        let found = list(#"{"schemaVersion": "\#(version)", "entries": [{"url": "  HTTPS://Example.com/A  "}]}"#)
        XCTAssertEqual(found?.entries.map(\.url), ["HTTPS://Example.com/A"])
    }

    func testTheSameLinkTwiceInOneFileComesInOnceAtItsFirstPlace() {
        let found = list("""
        {"schemaVersion": "\(version)", "entries": [
          {"url": "https://example.com/a", "title": "First"},
          {"url": "https://example.com/b"},
          {"url": "https://example.com/a", "title": "Second"}
        ]}
        """)
        XCTAssertEqual(found?.entries.map(\.url), ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(found?.entries.first?.title, "First")
    }

    func testAListWithNoUsableLinkIsRejectedAndNamesWhy() {
        for body in [#""entries": []"#, #""entries": "https://example.com/a""#, #""other": 1"#] {
            guard case .rejected(let message) = recognize(#"{"schemaVersion": "\#(version)", \#(body)}"#) else {
                return XCTFail("Expected a rejection for \(body)")
            }
            XCTAssertTrue(message.contains("no entries"), message)
        }
        guard case .rejected(let message) = recognize(#"{"schemaVersion": "\#(version)", "entries": [{"url": "http://example.com/a"}]}"#) else {
            return XCTFail("Expected a rejection")
        }
        XCTAssertTrue(message.contains("https"), message)
    }

    func testTheEntryLimitIsStatedAndTheWholeFileIsRefusedPastIt() {
        func file(_ count: Int) -> String {
            let entries = (1...count).map { #"{"url": "https://example.com/\#($0)"}"# }.joined(separator: ",")
            return #"{"schemaVersion": "\#(version)", "entries": [\#(entries)]}"#
        }
        XCTAssertEqual(list(file(LinkListFile.maxEntries))?.entries.count, LinkListFile.maxEntries)
        guard case .rejected(let message) = recognize(file(LinkListFile.maxEntries + 1)) else {
            return XCTFail("Expected a rejection past the limit")
        }
        XCTAssertTrue(message.contains("\(LinkListFile.maxEntries + 1)") && message.contains("\(LinkListFile.maxEntries)"), message)
    }

    func testAFileOverTheSizeLimitIsRefusedOnlyWhenItAnnouncesItself() {
        let padding = String(repeating: " ", count: LinkListFile.maxFileBytes)
        let announcing = Data((#"{"schemaVersion": "\#(version)", "entries": []}"# + padding).utf8)
        guard case .rejected(let message) = LinkListFile.recognize(announcing) else { return XCTFail("Expected a rejection") }
        XCTAssertTrue(message.contains("larger"), message)
        let other = Data((#"{"schemaVersion": "spoken-margins.listening-edition.v1"}"# + padding).utf8)
        XCTAssertEqual(LinkListFile.recognize(other), .notALinkList)
    }

    // MARK: - The note about what was left out

    func testTheSkippedNoteNamesUpToThreeAndCountsTheRest() {
        XCTAssertNil(LinkListFile.skippedNote([]))
        let skipped = (1...5).map { LinkListFile.SkippedEntry(position: $0, text: "http://e.com/\($0)", reason: "is not an https link") }
        XCTAssertEqual(
            LinkListFile.skippedNote(skipped),
            "Skipped: http://e.com/1 is not an https link; http://e.com/2 is not an https link; http://e.com/3 is not an https link and 2 more.")
        XCTAssertEqual(
            LinkListFile.skippedNote([LinkListFile.SkippedEntry(position: 4, text: nil, reason: "has no \"url\"")]),
            "Skipped: Entry 4 has no \"url\".")
    }
}
