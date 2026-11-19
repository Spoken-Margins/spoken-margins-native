import Foundation
import XCTest
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #4341 PR 2: Zotero's JSON read into papers. The two fixtures are real responses from Zotero's public "Test Items
/// Library" group (id 2205533, collection "APA, 6th edition"), fetched 2026-11-19 with `Zotero-API-Version: 3` and no
/// key: the first 25 of `collections/DMKBHP6P/items/top`, and that collection's `items?itemType=attachment`.
final class ZoteroPaperReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TestInputs.url(.contracts, "fixtures/feeds/\(name).json"))
    }

    private func page() throws -> PaperPage {
        try ZoteroPaperReader.read(
            items: fixture("zotero-group-collection"), attachments: [fixture("zotero-group-attachments")], groupID: 2205533
        )
    }

    private func entry(_ key: String, in page: PaperPage) throws -> PaperEntry {
        try XCTUnwrap(page.entries.first { $0.id == "zotero:2205533:\(key)" }, key)
    }

    // MARK: The real collection

    func testTheRealCollectionReadsAsPapersAndSkipsTheOneWithoutATitle() throws {
        let page = try page()
        XCTAssertEqual(page.entries.count, 24)
        XCTAssertEqual(page.skippedCount, 1, "QDNCCZW2 has an empty title and no short title")
        XCTAssertEqual(Set(page.entries.map(\.id)).count, 24, "no paper twice")
        XCTAssertFalse(page.entries.contains { $0.title.isEmpty })
    }

    func testStatusesOfTheRealCollection() throws {
        let page = try page()
        XCTAssertEqual(page.entries.filter { $0.status == .pdf }.count, 0, "no PDF in this library is reachable without a key")
        XCTAssertEqual(page.entries.filter { $0.status == .abstractOnly }.map { $0.id.suffix(8) }.sorted(),
                       ["34FJELMP", "742IUZMD", "MZCKNDMM", "PGJVUJ3P", "SFWYZJLW"])
        XCTAssertEqual(page.entries.filter { $0.status == .linkOnly }.count, 19)
        XCTAssertTrue(page.entries.allSatisfy { $0.pageURL != nil }, "Open always has somewhere to go")
    }

    func testAStoredPDFIsNotReachableWithoutAKeyButIsRemembered() throws {
        let page = try page()
        let thesis = try entry("JA3W6QNM", in: page)
        XCTAssertEqual(thesis.status, .linkOnly)
        XCTAssertNil(thesis.pdfURL)
        XCTAssertEqual(thesis.storedPDFAttachmentKey, "5B74JAMI")
        let paper = try entry("MZCKNDMM", in: page)
        XCTAssertEqual(paper.status, .abstractOnly, "an abstract is the next best thing to a PDF")
        XCTAssertEqual(paper.storedPDFAttachmentKey, "577MVUDU")
    }

    func testFieldsOfARealPaper() throws {
        let paper = try entry("742IUZMD", in: try page())
        XCTAssertEqual(paper.provider, .zotero)
        XCTAssertEqual(paper.authors, ["Gill", "Minton", "Myers"])
        XCTAssertEqual(paper.authorLine, "Gill, Minton et al.")
        XCTAssertEqual(paper.year, 2010, "from Zotero's parsedDate of '07/2010'")
        XCTAssertEqual(paper.doi, "10.1002/j.1556-6678.2010.tb00025.x")
        XCTAssertEqual(paper.pageURL?.absoluteString, "https://doi.org/10.1002/j.1556-6678.2010.tb00025.x", "the DOI's address first")
        XCTAssertNotNil(paper.journal)
        XCTAssertEqual(paper.abstract?.isEmpty, false)
        XCTAssertFalse(try XCTUnwrap(paper.abstract).contains("\n"), "line breaks in an abstract collapse to spaces")
    }

    func testPMIDComesFromItsField() throws {
        let paper = try entry("T52IAELZ", in: try page())
        XCTAssertEqual(paper.pmid, "16756431")
        XCTAssertEqual(paper.journal, "Developmental Psychology")
        XCTAssertEqual(paper.authorLine, "Greenfield, Yan")
    }

    func testAPaperWithNoDOIOrAddressOpensItsZoteroPage() throws {
        let program = try entry("GFSR2MSD", in: try page())
        XCTAssertNil(program.doi)
        XCTAssertEqual(program.pageURL?.absoluteString, "https://www.zotero.org/groups/test_items_library/items/GFSR2MSD")
    }

    func testPapersSortByWhenTheyJoinedNotWhenTheyWerePublished() throws {
        let page = try page()
        let entries = page.entries
        let joined = entries.compactMap(\.dateJoined)
        XCTAssertEqual(joined.count, entries.count)
        XCTAssertEqual(joined, joined.sorted(by: >))
        XCTAssertEqual(entries.first?.id, "zotero:2205533:34FJELMP", "added 2025-09-09, the newest in the page")
        XCTAssertEqual(try entry("34FJELMP", in: page).year, 2000, "published in 2000")
    }

    func testReadingWithoutTheAttachmentsListStillGivesPapers() throws {
        let page = try ZoteroPaperReader.read(items: fixture("zotero-group-collection"), groupID: 2205533)
        XCTAssertEqual(page.entries.count, 24)
        XCTAssertTrue(page.entries.allSatisfy { $0.storedPDFAttachmentKey == nil && $0.pdfURL == nil })
    }

    func testTodaysFeedParserDoesNotReadZoteroJSON() throws {
        // The Design's PR 1 question for Zotero: what does the existing follow make of this? Nothing: the response is a
        // JSON array, not a JSON Feed, so it goes down the XML path and fails. Zotero needs its own reader.
        let bytes = try fixture("zotero-group-collection")
        XCTAssertThrowsError(try FeedParser().parse(data: bytes, contentType: "application/json")) {
            XCTAssertEqual($0 as? FeedParserError, .malformed)
        }
    }

    // MARK: Attachments and statuses, built from the same shape

    private func json(_ objects: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: objects)
    }

    private func item(_ key: String = "AAAAAAAA", type: String = "journalArticle", extra: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = ["itemType": type, "title": "A title", "dateAdded": "2024-05-01T10:00:00Z"]
        for (name, value) in extra { data[name] = value }
        return ["key": key, "data": data, "meta": [String: Any]()]
    }

    private func attachment(parent: String = "AAAAAAAA", mode: String, type: String?, url: String? = nil, key: String = "BBBBBBBB") -> [String: Any] {
        var data: [String: Any] = ["itemType": "attachment", "parentItem": parent, "linkMode": mode]
        if let type { data["contentType"] = type }
        if let url { data["url"] = url }
        return ["key": key, "data": data]
    }

    private func read(_ items: [[String: Any]], _ attachments: [[String: Any]] = []) throws -> PaperPage {
        try ZoteroPaperReader.read(items: json(items), attachments: [json(attachments)], groupID: 1)
    }

    func testStatusTable() throws {
        let pdf = "https://example.org/paper.pdf"
        let rows: [(String, [String: Any], [[String: Any]], PaperEntryStatus, String)] = [
            ("linked PDF", [:], [attachment(mode: "linked_url", type: "application/pdf", url: pdf)], .pdf, "a linked PDF is fetchable"),
            ("linked PDF, upper case and a charset", [:],
             [attachment(mode: "linked_url", type: "Application/PDF; charset=binary", url: pdf)], .pdf, "type is read case-blind"),
            ("linked PDF beats the abstract", ["abstractNote": "Words."],
             [attachment(mode: "linked_url", type: "application/pdf", url: pdf)], .pdf, "PDF wins"),
            ("linked PDF with no address", [:], [attachment(mode: "linked_url", type: "application/pdf")], .linkOnly, "nothing to fetch"),
            ("linked PDF on a non-web address", [:],
             [attachment(mode: "linked_url", type: "application/pdf", url: "file:///Users/me/paper.pdf")], .linkOnly, "a file on the researcher's own computer"),
            ("linked PDF on ftp", [:],
             [attachment(mode: "linked_url", type: "application/pdf", url: "ftp://example.org/p.pdf")], .linkOnly, "web addresses only"),
            ("stored PDF", [:], [attachment(mode: "imported_file", type: "application/pdf")], .linkOnly, "stored files need a key"),
            ("stored PDF with an abstract", ["abstractNote": "Words."],
             [attachment(mode: "imported_url", type: "application/pdf", url: pdf)], .abstractOnly, "abstract is the fallback"),
            ("linked web page", [:], [attachment(mode: "linked_url", type: "text/html", url: "https://example.org/")], .linkOnly, "not a PDF"),
            ("linked file with no type", [:], [attachment(mode: "linked_url", type: nil, url: pdf)], .linkOnly, "unknown type is not a PDF"),
            ("abstract only", ["abstractNote": "Words."], [], .abstractOnly, "abstract"),
            ("blank abstract", ["abstractNote": "  \n "], [], .linkOnly, "whitespace is no abstract"),
            ("nothing", [:], [], .linkOnly, "bare record"),
            ("a PDF of some other paper", [:],
             [attachment(parent: "ZZZZZZZZ", mode: "linked_url", type: "application/pdf", url: pdf)], .linkOnly, "attachments belong to their parent")
        ]
        for (name, extra, attachments, expected, why) in rows {
            let page = try read([item(extra: extra)], attachments)
            XCTAssertEqual(page.entries.first?.status, expected, "\(name): \(why)")
        }
    }

    func testTheFirstUsableLinkedPDFIsKept() throws {
        let page = try read([item()], [
            attachment(mode: "linked_url", type: "application/pdf", url: "ftp://bad.example/p.pdf", key: "CCCCCCCC"),
            attachment(mode: "linked_url", type: "application/pdf", url: "https://good.example/p.pdf", key: "DDDDDDDD"),
            attachment(mode: "linked_url", type: "application/pdf", url: "https://later.example/p.pdf", key: "EEEEEEEE")
        ])
        XCTAssertEqual(page.entries.first?.pdfURL?.absoluteString, "https://good.example/p.pdf")
    }

    func testRowsThatAreNotPapersAreSkipped() throws {
        let rows = [item("AAAAAAAA"), item("NNNNNNNN", type: "note"), item("TTTTTTTT", type: "attachment"),
                    item("PPPPPPPP", type: "annotation"), item("QQQQQQQQ", extra: ["title": ""])]
        let page = try read(rows)
        XCTAssertEqual(page.entries.map(\.id), ["zotero:1:AAAAAAAA"])
        XCTAssertEqual(page.skippedCount, 4)
    }

    func testAShortTitleStandsInForAMissingTitle() throws {
        let page = try read([item(extra: ["title": "", "shortTitle": "Short"])])
        XCTAssertEqual(page.entries.first?.title, "Short")
    }

    func testTitlesAreTidied() throws {
        let page = try read([item(extra: ["title": "  A  title\nwith\tbreaks  "])])
        XCTAssertEqual(page.entries.first?.title, "A title with breaks")
    }

    func testFieldsOfTheWrongTypeReadAsAbsentInsteadOfFailingThePage() throws {
        let rows = [item("AAAAAAAA", extra: ["abstractNote": false, "DOI": 12, "url": ["x"], "creators": "nobody", "parentItem": false]),
                    item("BBBBBBBB")]
        let page = try read(rows)
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertEqual(page.entries[0].status, .linkOnly)
        XCTAssertEqual(page.entries[0].authors, [])
    }

    func testAuthorTable() throws {
        func authors(_ creators: [[String: String]]) throws -> [String] {
            try read([item(extra: ["creators": creators])]).entries.first?.authors ?? []
        }
        XCTAssertEqual(try authors([["creatorType": "author", "firstName": "Ada", "lastName": "Lovelace"]]), ["Lovelace"])
        XCTAssertEqual(try authors([["creatorType": "author", "name": "The Lancet Group"]]), ["The Lancet Group"], "a one-field author")
        XCTAssertEqual(try authors([["creatorType": "editor", "lastName": "Ed"], ["creatorType": "author", "lastName": "Au"]]), ["Au"], "authors first, no editors")
        XCTAssertEqual(try authors([["creatorType": "editor", "lastName": "Ed"]]), ["Ed"], "an editor when there is nobody else")
        XCTAssertEqual(try authors([["creatorType": "editor", "lastName": "Ed"], ["creatorType": "director", "lastName": "Di"]]), ["Di"])
        XCTAssertEqual(try authors([["creatorType": "author", "firstName": "Only"]]), [], "a first name alone is not a name")
        XCTAssertEqual(try authors([]), [])
    }

    func testAuthorLineTable() {
        func line(_ names: [String]) -> String {
            PaperEntry(id: "x", provider: .zotero, title: "t", authors: names).authorLine
        }
        XCTAssertEqual(line([]), "")
        XCTAssertEqual(line(["Smith"]), "Smith")
        XCTAssertEqual(line(["Smith", "Jones"]), "Smith, Jones")
        XCTAssertEqual(line(["Smith", "Jones", "Lee"]), "Smith, Jones et al.")
        XCTAssertEqual(line(["Smith", "Jones", "Lee", "Kim"]), "Smith, Jones et al.")
    }

    func testYearTable() {
        let cases: [(String?, String?, Int?)] = [
            ("2021", nil, 2021), ("2021-03", nil, 2021), ("1989-10-23", nil, 1989), (nil, "Spring 2007", 2007),
            (nil, "02/2000", 2000), (nil, "March 3, 1999", 1999), (nil, "2021–2022", 2021), ("", "2020", 2020),
            (nil, "year", nil), (nil, "12345", nil), (nil, "0999", nil), (nil, "3000", nil), (nil, "", nil), (nil, nil, nil),
            (nil, "\u{0662}\u{0660}\u{0662}\u{0661}", nil), (nil, "vol. 1921a", 1921), (nil, "ISBN 9781234567890", nil)
        ]
        for (parsed, date, expected) in cases {
            XCTAssertEqual(ZoteroPaperReader.year(parsedDate: parsed, date: date), expected, "\(parsed ?? "nil") / \(date ?? "nil")")
        }
    }

    func testDOITable() {
        let canonical = "10.1037/0012-1649.42.3.391"
        let cases: [(String?, String?)] = [
            (canonical, canonical),
            ("10.1037/0012-1649.42.3.391 ", canonical),
            ("DOI:10.1037/0012-1649.42.3.391", canonical),
            ("doi: 10.1037/0012-1649.42.3.391", canonical),
            ("https://doi.org/10.1037/0012-1649.42.3.391", canonical),
            ("http://dx.doi.org/10.1037/0012-1649.42.3.391", canonical),
            ("HTTPS://DOI.ORG/10.1037/0012-1649.42.3.391", canonical),
            ("10.1002/J.1556-6678.2010.TB00025.X", "10.1002/j.1556-6678.2010.tb00025.x"),
            ("10.1002/(sici)1097-4571%2819930101%2944", "10.1002/(sici)1097-4571(19930101)44"),
            ("", nil), ("   ", nil), (nil, nil), ("xxxxx", nil), ("10.1037", nil), ("11.1037/abc", nil), ("10.1037/a b", nil),
            ("https://example.org/10.1037/abc", nil)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ZoteroPaperReader.normalizedDOI(raw), expected, raw ?? "nil")
        }
    }

    func testPMIDFromExtra() throws {
        func pmid(_ extra: String) throws -> String? {
            try read([item(extra: ["extra": extra])]).entries.first?.pmid
        }
        XCTAssertEqual(try pmid("PMID: 123456"), "123456")
        XCTAssertEqual(try pmid("genre: x\npmid:98765\nother: y"), "98765")
        XCTAssertNil(try pmid("PMID: abc"))
        XCTAssertNil(try pmid("PMCID: PMC123"))
        XCTAssertNil(try pmid("note about PMID: 5"))
        XCTAssertEqual(try read([item(extra: ["PMID": "42", "extra": "PMID: 7"])]).entries.first?.pmid, "42", "the field beats the extra line")
    }

    func testPageURLTable() throws {
        func open(_ extra: [String: Any], links: [String: Any]? = nil) throws -> String? {
            var row = item(extra: extra)
            if let links { row["links"] = links }
            return try read([row]).entries.first?.pageURL?.absoluteString
        }
        let zotero: [String: Any] = ["alternate": ["href": "https://www.zotero.org/groups/1/x/items/AAAAAAAA"]]
        XCTAssertEqual(try open(["DOI": "10.1/x", "url": "https://example.org/p"], links: zotero), "https://doi.org/10.1/x")
        XCTAssertEqual(try open(["url": "https://example.org/p"], links: zotero), "https://example.org/p")
        XCTAssertEqual(try open(["url": "javascript:alert(1)"], links: zotero), "https://www.zotero.org/groups/1/x/items/AAAAAAAA")
        XCTAssertEqual(try open(["url": "http://xxxxx"], links: zotero), "http://xxxxx", "a web address as written")
        XCTAssertNil(try open([:]))
    }

    func testTheNewestFiveHundredAreKeptAndTiesKeepLibraryOrder() throws {
        let rows = (0..<520).map { index in
            item(String(format: "K%07d", index), extra: ["title": "Paper \(index)", "dateAdded": index < 10 ? "2024-01-01T00:00:00Z" : "2024-02-01T00:00:00Z"])
        }
        let page = try read(rows)
        XCTAssertEqual(page.entries.count, 500)
        XCTAssertEqual(page.entries.first?.title, "Paper 10", "tied papers stay in the order the library gave them")
        XCTAssertEqual(page.entries.last?.title, "Paper 509", "the last of the tied papers that fit")
        XCTAssertFalse(page.entries.contains { $0.title == "Paper 0" }, "papers added earlier are dropped before later ones")
        XCTAssertFalse(page.entries.contains { $0.title == "Paper 510" }, "the tied papers past the cap are dropped")
    }

    func testOneUnreadableRowCostsOnlyThatRow() throws {
        let bytes = Data(#"[{"key":"A","data":{"itemType":"book","title":"x"}},{"key":"B","data":{"title":"y"}},{"data":{"itemType":"book","title":"z"}},7]"#.utf8)
        let page = try ZoteroPaperReader.read(items: bytes, groupID: 1)
        XCTAssertEqual(page.entries.map(\.id), ["zotero:1:A"])
        XCTAssertEqual(page.skippedCount, 3)
    }

    func testABrokenAttachmentsPageLeavesThePapersListed() throws {
        let items = try json([item(extra: ["abstractNote": "Words."])])
        for bad in [Data(), Data("nope".utf8), Data(#"{"message":"slow down"}"#.utf8), Data(#"[{"key":"X"}]"#.utf8)] {
            let page = try ZoteroPaperReader.read(items: items, attachments: [bad], groupID: 1)
            XCTAssertEqual(page.entries.map(\.status), [.abstractOnly])
        }
        let good = try json([attachment(mode: "linked_url", type: "application/pdf", url: "https://example.org/p.pdf")])
        let mixed = try ZoteroPaperReader.read(items: items, attachments: [Data("nope".utf8), good], groupID: 1)
        XCTAssertEqual(mixed.entries.map(\.status), [.pdf], "a good page after a bad one still counts")
    }

    func testAddressesWithAUserNameAreNotKept() throws {
        let pdf = attachment(mode: "linked_url", type: "application/pdf", url: "https://u:p@h.example/a.pdf")
        let page = try read([item(extra: ["url": "https://user@h.example/a"])], [pdf])
        XCTAssertNil(page.entries.first?.pageURL)
        XCTAssertNil(page.entries.first?.pdfURL)
    }

    func testADOIWithCharactersThatEndAPathStaysOneDOIInItsAddress() throws {
        let page = try read([item(extra: ["DOI": "10.1000/a#b?c%d"])])
        XCTAssertEqual(page.entries.first?.doi, "10.1000/a#b?c%d")
        XCTAssertEqual(page.entries.first?.pageURL?.absoluteString, "https://doi.org/10.1000/a%23b%3Fc%25d")
    }

    func testNotJSONAndTooLargeAreErrorsNotCrashes() throws {
        XCTAssertThrowsError(try ZoteroPaperReader.read(items: Data("<html>".utf8), groupID: 1)) {
            XCTAssertEqual($0 as? ZoteroPaperReaderError, .notZoteroJSON)
        }
        XCTAssertThrowsError(try ZoteroPaperReader.read(items: Data("{\"message\":\"forbidden\"}".utf8), groupID: 1)) {
            XCTAssertEqual($0 as? ZoteroPaperReaderError, .notZoteroJSON, "an error object is not a list")
        }
        XCTAssertThrowsError(try ZoteroPaperReader.read(items: Data(count: ZoteroPaperReader.maximumBytes + 1), groupID: 1)) {
            XCTAssertEqual($0 as? ZoteroPaperReaderError, .responseTooLarge)
        }
        XCTAssertEqual(try ZoteroPaperReader.read(items: Data("[]".utf8), groupID: 1), PaperPage(entries: [], skippedCount: 0))
    }
}
