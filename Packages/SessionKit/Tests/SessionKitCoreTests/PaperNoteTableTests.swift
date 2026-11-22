import Foundation
import XCTest
@testable import SessionKit

/// #4340 PR 2: the table of Paper notes, both file formats.
final class PaperNoteTableTests: XCTestCase {
    /// Four segments on two pages, so the first and third have a known page (1 and 2): see `pageNumber(atCharacter:)`.
    private let text = "Page one first. Page one second.\nPage two first. Page two last."
    private lazy var document = StructuredDocument(
        extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
        text: text,
        segments: [
            .init(id: "s0", role: .body, range: .init(start: 0, length: 15), pageIndex: 0),
            .init(id: "s1", role: .body, range: .init(start: 16, length: 16), pageIndex: 0),
            .init(id: "s2", role: .body, range: .init(start: 33, length: 15), pageIndex: 1),
            .init(id: "s3", role: .body, range: .init(start: 49, length: 14), pageIndex: 1),
        ],
        markers: []
    )
    private let onPage1 = 2
    private let onPage2 = 35

    private func margin(
        _ id: String, _ role: PaperNoteRole?, _ words: String?, at start: Int = 2, item: String = "p1", created: Double = 1,
        status: String = "active", target: InterjectionTargetType = .item
    ) -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: "s", targetType: target, targetId: item,
            createdAt: Date(timeIntervalSince1970: created), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: start, endChar: start + 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: words, status: status, captureKind: .written, paperRole: role
        )
    }

    private func paper(
        id: String = "p1", title: String = "A Paper", author: String? = nil, bibliography: PDFBibliography? = nil,
        withDocument: Bool = true, _ margins: [Interjection]
    ) -> PaperNoteTable.Paper {
        .init(itemId: id, title: title, author: author, bibliography: bibliography, document: withDocument ? document : nil, margins: margins)
    }

    private func cells(_ table: PaperNoteTable, row: Int = 0) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(PaperNoteTable.columns, table.rows[row]))
    }

    func testAFullPaperFillsEveryColumn() {
        let table = PaperNoteTable(papers: [paper(
            author: "Item Author",
            bibliography: PDFBibliography(doi: "10.1234/abcd", authors: ["Smith", "Jones"], year: 2021),
            [
                margin("a", .purpose, "To test sleep", at: onPage1),
                margin("b", .keyFinding, "It helped", at: onPage2),
                margin("c", .evidence, "Figure 2", at: onPage1),
                margin("d", .evidence, "Table 1", at: onPage2),
                margin("e", .evidence, "Methods", at: onPage2 + 3),
            ]
        )])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].count, PaperNoteTable.columns.count)
        let row = cells(table)
        XCTAssertEqual(row["Title"], "A Paper")
        XCTAssertEqual(row["Authors"], "Smith, Jones")
        XCTAssertEqual(row["Year"], "2021")
        XCTAssertEqual(row["DOI or arXiv"], "10.1234/abcd")
        XCTAssertEqual(row["Purpose"], "To test sleep")
        XCTAssertEqual(row["Purpose page"], "1")
        XCTAssertEqual(row["Key findings"], "It helped")
        XCTAssertEqual(row["Key findings page"], "2")
        XCTAssertEqual([row["Evidence 1"], row["Evidence 2"], row["Evidence 3"]], ["Figure 2", "Table 1", "Methods"])
        XCTAssertEqual([row["Evidence 1 page"], row["Evidence 2 page"]], ["1", "2"])
        XCTAssertEqual(row["More evidence"], "")
    }

    func testFewerThanThreeEvidenceLeavesTheRestBlank() {
        let row = cells(PaperNoteTable(papers: [paper([margin("c", .evidence, "Only one", at: onPage1)])]))
        XCTAssertEqual(row["Evidence 1"], "Only one")
        XCTAssertEqual([row["Evidence 2"], row["Evidence 2 page"], row["Evidence 3"], row["Evidence 3 page"], row["More evidence"]], ["", "", "", "", ""])
        XCTAssertEqual([row["Purpose"], row["Key findings"]], ["", ""])
    }

    func testAFourthAndLaterEvidenceGoesInMoreEvidenceWithItsPage() {
        let row = cells(PaperNoteTable(papers: [paper([
            margin("e1", .evidence, "one", at: onPage1), margin("e2", .evidence, "two", at: onPage1, created: 2),
            margin("e3", .evidence, "three", at: onPage1, created: 3), margin("e4", .evidence, "four", at: onPage2),
            margin("e5", .evidence, "five", at: 20),
        ])]))
        XCTAssertEqual([row["Evidence 1"], row["Evidence 2"], row["Evidence 3"]], ["one", "two", "three"])
        XCTAssertEqual(row["More evidence"], "four (p. 2) / five", "a Margin with no known page carries no page")
    }

    func testARoleAnsweredTwiceJoinsInPageOrderWithPagesAlongside() {
        let row = cells(PaperNoteTable(papers: [paper([
            margin("late", .keyFinding, "On page two", at: onPage2, created: 1),
            margin("early", .keyFinding, "On page one", at: onPage1, created: 2),
        ])]))
        XCTAssertEqual(row["Key findings"], "On page one / On page two")
        XCTAssertEqual(row["Key findings page"], "1 / 2")
    }

    func testNoCitationUsesTheItemTitleAndAuthorAndNoBibliographyLeavesYearAndDOIBlank() {
        let row = cells(PaperNoteTable(papers: [paper(title: "Untitled scan", author: "Dana", [margin("a", .purpose, "x")])]))
        XCTAssertEqual([row["Title"], row["Authors"], row["Year"], row["DOI or arXiv"]], ["Untitled scan", "Dana", "", ""])
        let none = cells(PaperNoteTable(papers: [paper([margin("a", .purpose, "x")])]))
        XCTAssertEqual(none["Authors"], "")
        let arxiv = cells(PaperNoteTable(papers: [paper(author: "Fallback", bibliography: PDFBibliography(arxivId: "2101.00001"), [margin("a", .purpose, "x")])]))
        XCTAssertEqual(arxiv["DOI or arXiv"], "arXiv:2101.00001")
        XCTAssertEqual(arxiv["Authors"], "Fallback", "a bibliography with no authors falls back to the item's")
        let blankDOI = cells(PaperNoteTable(papers: [paper(bibliography: PDFBibliography(doi: "", arxivId: "2101.00001"), [margin("a", .purpose, "x")])]))
        XCTAssertEqual(blankDOI["DOI or arXiv"], "arXiv:2101.00001")
    }

    func testOnlyPapersWithAnAnswerInScopeGetARow() {
        let papers = [
            paper(id: "with", title: "With", [margin("a", .purpose, "x", item: "with")]),
            paper(id: "plain", title: "Plain", [margin("b", nil, "x", item: "plain")]),
            // A friend's Margins are another type and are never passed in, so a paper that only has them has none to give.
            paper(id: "friends-only", title: "Friends", []),
            paper(id: "out", title: "Out", [margin("c", .purpose, "x", item: "out")]),
            paper(id: "blank", title: "Blank", [margin("d", .purpose, "  \n ", item: "blank")]),
            paper(id: "trashed", title: "Trashed", [margin("e", .purpose, "x", item: "trashed", status: "deleted")]),
            paper(id: "turn", title: "Turn", [margin("f", .purpose, "x", item: "turn", target: .summaryTurn)]),
            paper(id: "elsewhere", title: "Elsewhere", [margin("g", .purpose, "x", item: "another-item")]),
        ]
        XCTAssertEqual(PaperNoteTable(papers: papers).rows.map { $0[0] }.sorted(), ["Out", "With"])
        XCTAssertEqual(PaperNoteTable(papers: papers, scope: ["with", "plain", "friends-only"]).rows.map { $0[0] }, ["With"])
        XCTAssertTrue(PaperNoteTable(papers: papers, scope: []).isEmpty)
        XCTAssertTrue(PaperNoteTable(papers: []).isEmpty)
    }

    func testRowsRunNewestAnswerFirst() {
        let table = PaperNoteTable(papers: [
            paper(id: "old", title: "Old", [margin("a", .purpose, "x", item: "old", created: 10), margin("a2", .purpose, "x", item: "old", created: 11)]),
            paper(id: "new", title: "New", [margin("b", .purpose, "x", item: "new", created: 50)]),
            paper(id: "mid", title: "Mid", [margin("c", .purpose, "x", item: "mid", created: 20), margin("c2", nil, "ignored", item: "mid", created: 999)]),
            paper(id: "tie-b", title: "B tie", [margin("d", .purpose, "x", item: "tie-b", created: 5)]),
            paper(id: "tie-a", title: "A tie", [margin("e", .purpose, "x", item: "tie-a", created: 5)]),
        ])
        XCTAssertEqual(table.rows.map { $0[0] }, ["New", "Mid", "Old", "A tie", "B tie"])
    }

    func testTheTextIsTheShownTextInTheAppsOrder() {
        var spoken = margin("s", .purpose, nil)
        spoken.transcript = "raw words"
        spoken.cleanedTranscript = "clean words"
        XCTAssertEqual(cells(PaperNoteTable(papers: [paper([spoken])]))["Purpose"], "clean words")
        spoken.displayText = "approved words"
        XCTAssertEqual(cells(PaperNoteTable(papers: [paper([spoken])]))["Purpose"], "approved words")
    }

    func testWithoutADocumentThePageCellsAreEmpty() {
        let row = cells(PaperNoteTable(papers: [paper(withDocument: false, [margin("a", .purpose, "x")])]))
        XCTAssertEqual([row["Purpose"], row["Purpose page"]], ["x", ""])
    }

    // MARK: Files

    private var awkward: PaperNoteTable {
        PaperNoteTable(papers: [paper(title: "Café, “Naïve” 😀", author: "O'Neil", [
            margin("a", .purpose, "He said \"hi\", then left"),
            margin("b", .keyFinding, "line one\nline two | pipe"),
            margin("c", .evidence, "=SUM(A1:A2)", created: 2),
            margin("d", .evidence, "+1 more", at: onPage2),
            margin("e", .evidence, "-5 percent", at: onPage2),
            margin("f", .evidence, "@mention", at: onPage2 + 1),
        ])])
    }

    func testCSVQuotesCommasQuotesAndLineBreaksAndGuardsFormulas() throws {
        let csv = awkward.csv()
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.last, "", "ends with CRLF")
        XCTAssertEqual(lines[0], PaperNoteTable.columns.joined(separator: ","))
        XCTAssertTrue(csv.contains("\"Café, “Naïve” 😀\""), "a comma forces quotes; accents and emoji pass through")
        XCTAssertTrue(csv.contains("\"He said \"\"hi\"\", then left\""))
        XCTAssertTrue(csv.contains("\"line one\nline two | pipe\""), "a line break stays inside its quoted cell")
        for formula in ["'=SUM(A1:A2)", "'+1 more", "'-5 percent", "'@mention"] {
            XCTAssertTrue(csv.contains(formula), formula)
        }
        XCTAssertFalse(csv.contains(",=SUM"))
        XCTAssertEqual(parseCSV(csv).dropFirst().first?.count, PaperNoteTable.columns.count)
        XCTAssertEqual(parseCSV(csv).dropFirst().first?[5], "1", "the Purpose page")
        XCTAssertEqual(parseCSV(csv).dropFirst().first?[6], "line one\nline two | pipe", "the line break survives a spreadsheet read")
    }

    func testCSVDataStartsWithAByteOrderMarkAndDecodesBack() throws {
        let data = awkward.csvData()
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(decoding: data.dropFirst(3), as: UTF8.self), awkward.csv())
    }

    func testAnEmptyTableStillHasAHeader() {
        XCTAssertEqual(PaperNoteTable(papers: []).csv(), PaperNoteTable.columns.joined(separator: ",") + "\r\n")
        XCTAssertEqual(PaperNoteTable(papers: []).markdown().components(separatedBy: "\n").count, 3)
    }

    func testMarkdownEscapesPipesAndTurnsLineBreaksIntoBreakTags() {
        let lines = awkward.markdown().components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4, "header, rule, one row, trailing newline")
        XCTAssertTrue(lines[1].hasPrefix("| --- |"))
        XCTAssertTrue(lines[2].contains("line one<br>line two \\| pipe"))
        XCTAssertTrue(lines[2].contains("Café, “Naïve” 😀"))
        // Every row has the same number of unescaped separators as the header.
        func separators(_ line: String) -> Int { line.replacingOccurrences(of: "\\|", with: "").filter { $0 == "|" }.count }
        XCTAssertEqual(separators(lines[2]), separators(lines[0]))
    }

    func testMarkdownEscapingSurvivesBackslashesCombiningMarksAndEveryLineBreak() {
        let nasty = [
            "a\\|b", "a|\u{301}b", "a\n\u{301}b", "x\r\ny\rz", "u\u{2028}v\u{85}w", "C:\\path\\file",
        ]
        let table = PaperNoteTable(papers: nasty.enumerated().map { index, words in
            paper(id: "p\(index)", title: "T\(index)", [margin("m\(index)", .purpose, words, item: "p\(index)")])
        })
        let lines = table.markdown().components(separatedBy: "\n")
        XCTAssertEqual(lines.count, nasty.count + 3, "one line per row: no cell ended its row")
        func separators(_ line: String) -> Int {
            var count = 0, escaped = false
            for character in line.unicodeScalars {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "|" { count += 1 }
            }
            return count
        }
        for line in lines.dropFirst(2).dropLast() { XCTAssertEqual(separators(line), separators(lines[0]), line) }
        let all = table.markdown()
        XCTAssertTrue(all.contains("a\\\\\\|b"), "the backslash is escaped, then the pipe")
        XCTAssertTrue(all.contains("x<br>y<br>z"))
        XCTAssertTrue(all.contains("u<br>v<br>w"))
        XCTAssertTrue(all.contains("C:\\\\path\\\\file"))
    }

    func testCSVDoublesAQuoteThatACombiningMarkFollowsAndGuardsLeadingWhitespaceFormulas() {
        let table = PaperNoteTable(papers: [
            paper(id: "a", title: "say \"\u{301}x", author: "\t=HYPERLINK(\"x\")", [margin("a", .purpose, "x", item: "a", created: 3)]),
            paper(id: "b", title: " =1+1", author: "\r+2", [margin("b", .purpose, "x\r\ny", item: "b", created: 2)]),
        ])
        let rows = parseCSV(table.csv())
        XCTAssertEqual(rows[1][0], "say \"\u{301}x")
        XCTAssertEqual(rows[1][1], "'\t=HYPERLINK(\"x\")")
        XCTAssertEqual(rows[2][0], "' =1+1")
        XCTAssertEqual(rows[2][1], "'\r+2")
        XCTAssertEqual(rows[2][4], "x\r\ny", "a CRLF inside a cell survives a spreadsheet read")
    }

    func testEqualPagesOrderByPositionThenCreationThenIdAndPaddedTextIsTrimmed() {
        let row = cells(PaperNoteTable(papers: [paper([
            margin("z", .keyFinding, "  later position  ", at: onPage1 + 4, created: 1),
            margin("b", .keyFinding, "same spot, later", at: onPage1, created: 2),
            margin("c", .keyFinding, "same spot, same time, id c", at: onPage1, created: 2),
            margin("a", .keyFinding, "\n same spot, earlier \n", at: onPage1, created: 1),
        ])]))
        XCTAssertEqual(row["Key findings"], "same spot, earlier / same spot, later / same spot, same time, id c / later position")
        XCTAssertEqual(row["Key findings page"], "1 / 1 / 1 / 1")
    }

    func testThreeHundredPapersWithTenAnswersEachBuildQuickly() {
        let papers = (0..<300).map { index in
            paper(id: "p\(index)", title: "Paper \(index)", (0..<10).map {
                margin("m\(index)-\($0)", [.purpose, .keyFinding, .evidence][$0 % 3], "answer \($0)", at: $0 % 2 == 0 ? onPage1 : onPage2, item: "p\(index)", created: Double($0))
            })
        }
        let started = Date()
        let table = PaperNoteTable(papers: papers)
        _ = table.csv()
        _ = table.markdown()
        XCTAssertEqual(table.rows.count, 300)
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.02 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a table build that rescans every paper per answer.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A small RFC 4180 reader, so the test reads the file the way a spreadsheet would.
    private func parseCSV(_ csv: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let characters = Array(csv.unicodeScalars)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { field.unicodeScalars.append(c); index += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true
            } else if c == "," { row.append(field); field = ""
            } else if c == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                row.append(field); rows.append(row); row = []; field = ""; index += 1
            } else { field.unicodeScalars.append(c) }
            index += 1
        }
        return rows
    }
}
