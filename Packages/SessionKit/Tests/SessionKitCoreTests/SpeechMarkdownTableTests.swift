import XCTest
@testable import SessionKit

/// #4048: a web article's table reached speech as raw markdown rows, and the voice read the pipes aloud.
final class SpeechMarkdownTableTests: XCTestCase {
    private let notice = "Table not read."

    func testTheNoticeIsTheOneADocumentTableGets() {
        guard case .announceAndSkip(let documentNotice) = DocumentSpeechRules.treatment(forRole: "table") else {
            return XCTFail("a document table is announced and skipped")
        }
        XCTAssertEqual(SpeechTextNormalizer.tableNotice, documentNotice)
    }

    /// The export from the owner's phone, 2026-11-10.
    func testTheOwnersFiveRowComparisonTableBecomesTheNotice() {
        let source = """
        Here is the comparison.

        | Your wish | OPML 2.0 | Podcasting 2.0 | Bluesky |
        | --- | --- | --- | --- |
        | One source in several lists | Yes · category tags | Yes · stable IDs | Yes |
        | Names a podcast | Yes | Yes | No |
        | Carries a note | No | Yes | Yes |
        | Works offline | Yes | No | No |
        | Imports in one tap | No | No | Yes |

        Segment 7 begins now.
        """
        let spoken = SpeechTextNormalizer.normalize(source)
        XCTAssertEqual(spoken, "Here is the comparison. \(notice) Segment 7 begins now.")
        XCTAssertEqual(SpeechTextNormalizer.projectForSystemSpeech(source).text, spoken)
    }

    /// Each row is a table in one shape or another; all of them go.
    func testTableShapesAllBecomeTheNotice() {
        let tables = [
            "a | b\n--- | ---\n1 | 2",                       // no outer pipes
            "| a | b |\n|:---|---:|\n| 1 | 2 |",              // alignment colons
            "| a | b |\n|:---:|:---:|\n| 1 | 2 |",
            "| only |\n| --- |\n| one |\n| column |",         // one column
            "| a | b |\n| --- | --- |",                       // header and separator, no body rows
            "|a|b|\n|-|-|\n|1|2|",                            // no spaces, one-dash separator
            "| a | b |   \n| --- | --- |  \n| 1 | 2 |  ",      // trailing spaces
            "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |",        // Windows line endings
            "  | a | b |\n  | --- | --- |\n  | 1 | 2 |",      // up to three spaces of indent
            "| a \\| b | c |\n| --- | --- |\n| 1 \\| 2 | 3 |", // escaped pipes stay inside a cell
        ]
        for table in tables {
            XCTAssertEqual(SpeechTextNormalizer.normalize(table), notice, table)
            XCTAssertEqual(SpeechTextNormalizer.normalize("Before.\n\n\(table)\n\nAfter."), "Before. \(notice) After.", table)
        }
    }

    func testATableAtTheStartOrEndOfTheTextIsReplacedWithoutLosingTheText() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("| a | b |\n| --- | --- |\n| 1 | 2 |\nThen it ends."), "\(notice) Then it ends.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("It starts.\n| a | b |\n| --- | --- |\n| 1 | 2 |"), "It starts. \(notice)")
    }

    func testTwoTablesEachGetTheNotice() {
        let source = "| a |\n| - |\n| 1 |\n\nBetween.\n\n| b |\n| - |\n| 2 |"
        XCTAssertEqual(SpeechTextNormalizer.normalize(source), "\(notice) Between. \(notice)")
    }

    func testPipesThatAreNotATableStayWords() {
        let keep = [
            "Choose a | b for the either-or.",
            "Use the | key, then press enter.\nIt works.",
            "a | b\nnot a separator\nc | d",
            "A heading\n---\nBody text with a | pipe.",     // a rule line with no pipe
            "| a | b |\n| --- |\n| 1 | 2 |",                 // header has two cells, separator one
            "| a |\n| --- | --- |\n| 1 |",                   // header has one cell, separator two
            "x | y\n| --- |\nz",                                 // header has two cells, separator one, no outer pipes
            "a | b\n--- ---\nplain",                          // separator without a pipe
            "    | a | b |\n    | --- | --- |\n    | 1 | 2 |", // indented four spaces: code, not a table
        ]
        for text in keep {
            let spoken = SpeechTextNormalizer.normalize(text)
            XCTAssertFalse(spoken.contains(notice), text)
            XCTAssertTrue(spoken.contains("|"), text)
        }
    }

    func testCodeBlocksThatContainTablesKeepTheirPipes() {
        let fenced = "Run this:\n\n```\n| a | b |\n| --- | --- |\n| 1 | 2 |\n```\n\nDone."
        let spoken = SpeechTextNormalizer.normalize(fenced)
        XCTAssertFalse(spoken.contains(notice))
        XCTAssertTrue(spoken.contains("| a | b |"))
        // A table after the fence closes is a table again.
        let after = SpeechTextNormalizer.normalize("```\ncode | here\n```\n\n| a |\n| - |\n| 1 |")
        XCTAssertTrue(after.hasSuffix(notice), after)
        // Tilde fences, and a longer closing fence.
        let tilde = SpeechTextNormalizer.normalize("~~~\n| a |\n| - |\n~~~~\nText.")
        XCTAssertFalse(tilde.contains(notice), tilde)
    }

    func testAShortBacktickRunIsNotAFence() {
        let source = "Say ``` here.\n\n| a |\n| - |\n| 1 |"
        XCTAssertEqual(SpeechTextNormalizer.normalize(source), "Say ``` here. \(notice)")
    }

    func testTheNoticeMapsBackToTheTableInTheSource() throws {
        let source = "Intro.\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nOutro."
        let projected = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        let noticeStart = projected.text.distance(from: projected.text.startIndex, to: try XCTUnwrap(projected.text.range(of: notice)).lowerBound)
        let tableStart = source.distance(from: source.startIndex, to: try XCTUnwrap(source.range(of: "| a | b |")).lowerBound)
        XCTAssertEqual(projected.sourceOffsets[noticeStart], tableStart)
        let outroStart = projected.text.distance(from: projected.text.startIndex, to: try XCTUnwrap(projected.text.range(of: "Outro")).lowerBound)
        XCTAssertEqual(projected.sourceOffsets[outroStart], source.distance(from: source.startIndex, to: try XCTUnwrap(source.range(of: "Outro")).lowerBound))
    }

    /// Import cleaning keeps stored text byte-identical (I13 rule 1a), so it leaves a table alone.
    func testImportCleaningKeepsATableAsItWas() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        XCTAssertEqual(SpeechTextNormalizer.normalizeImportedText(source), "| a | b | | --- | --- | | 1 | 2 |")
    }

    func testTextWithoutPipesIsUntouched() {
        let source = "Plain text.\n\nNo tables at all."
        XCTAssertEqual(SpeechTextNormalizer.normalize(source), "Plain text. No tables at all.")
    }

    /// Review finding: a sentence or list item with a pipe right after a table was taken as one more row and deleted.
    func testProseWithAPipeDirectlyAfterATableStaysText() {
        XCTAssertEqual(
            SpeechTextNormalizer.normalize("| a | b |\n| --- | --- |\n| 1 | 2 |\nThis sentence has a | pipe in it.\nNext line."),
            "\(notice) This sentence has a | pipe in it. Next line."
        )
        XCTAssertEqual(
            SpeechTextNormalizer.normalize("| a |\n| - |\n| 1 |\n- item | with pipe\n"),
            "\(notice) - item | with pipe"
        )
        // No outer pipes: a row has the header's number of cells, so a line with one pipe and two cells ends a
        // three-column table.
        XCTAssertEqual(
            SpeechTextNormalizer.normalize("a | b | c\n--- | --- | ---\n1 | 2 | 3\nSee x | y here."),
            "\(notice) See x | y here."
        )
    }

    func testRowsWithOddCellCountsStayInATableThatHasEdgePipes() {
        let source = "| a | b | c |\n| --- | --- | --- |\n| merged cell |\n| 1 | 2 |\nAfter."
        XCTAssertEqual(SpeechTextNormalizer.normalize(source), "\(notice) After.")
    }

    /// Review finding: one stray fence line with no closer switched table replacement off for the rest of the text.
    func testAnUnclosedFenceLineDoesNotHideLaterTables() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("~~~\nfoo\n\n| a |\n| - |\n| 1 |"), "~~~ foo \(notice)")
        XCTAssertEqual(SpeechTextNormalizer.normalize("```js\nlet x\n\n| a |\n| - |\n| 1 |"), "```js let x \(notice)")
        // A fence that does close still protects what is inside it.
        let closed = SpeechTextNormalizer.normalize("```\n| a |\n| - |\n| 1 |\n```")
        XCTAssertFalse(closed.contains(notice), closed)
    }

    // MARK: Speech that starts inside a table (#4189)

    /// Jumping to a Margin anchored in a table row, or resuming from a saved place inside one, starts speech from an
    /// offset in the middle of the table. The tail alone has no header row, so the table rule saw no table and the
    /// voice read the pipes.
    private func characterOffset(of needle: String, in text: String) throws -> Int {
        text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: needle), needle).lowerBound)
    }

    private func assertSpeechFromInsideATable(prefix: String, underTheMemoMinimum: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let table = "| Your wish | OPML 2.0 |\n| --- | --- |\n| Names a podcast | Yes |\n| Carries a note | No |"
        let source = "\(prefix)Intro.\n\n\(table)\n\nOutro."
        XCTAssertEqual(source.utf8.count < SpeechProjectionMemo.minimumBytes, underTheMemoMinimum, file: file, line: line)
        let tableStart = try characterOffset(of: "| Your wish", in: source)
        let tableEnd = tableStart + table.count
        let outro = try characterOffset(of: "Outro.", in: source)
        let named: [(String, Int)] = [
            ("on the header", tableStart),
            ("inside the header", tableStart + 4),
            ("on the separator line", try characterOffset(of: "| --- |", in: source)),
            ("inside a row", try characterOffset(of: "podcast", in: source)),
            ("on the last row", try characterOffset(of: "| Carries", in: source)),
            ("on the last cell", try characterOffset(of: "No |", in: source)),
            ("on the table's final pipe", tableEnd - 1),
            ("just after the table", tableEnd),
            ("on the blank line after the table", tableEnd + 1),
            ("on the outro", outro),
        ]
        for (name, offset) in named {
            let spoken = SpeechTextNormalizer.projectForSystemSpeech(source, fromSourceOffset: offset)
            XCTAssertFalse(spoken.text.contains("|"), "\(name) (offset \(offset)): \(spoken.text)", file: file, line: line)
            XCTAssertFalse(spoken.text.contains("---"), "\(name) (offset \(offset)): \(spoken.text)", file: file, line: line)
            XCTAssertFalse(spoken.text.contains("podcast"), "\(name) (offset \(offset)): \(spoken.text)", file: file, line: line)
            // From the header on, the table is announced; from inside it, speech goes on to the text after it. Both
            // are what a play from the start says at that point, so a short text reads like a long one.
            XCTAssertEqual(spoken.text, offset == tableStart ? "\(notice) Outro." : "Outro.", "\(name) (offset \(offset))", file: file, line: line)
            XCTAssertEqual(spoken.sourceLength, source.count, file: file, line: line)
            XCTAssertTrue(spoken.sourceOffsets.allSatisfy { $0 >= offset }, "\(name)", file: file, line: line)
        }
        // Every offset in the table, not only the named ones.
        for offset in tableStart..<tableEnd {
            let spoken = SpeechTextNormalizer.projectForSystemSpeech(source, fromSourceOffset: offset)
            XCTAssertFalse(spoken.text.contains("|"), "offset \(offset): \(spoken.text)", file: file, line: line)
        }
    }

    func testSpeechFromInsideATableInAShortTextDoesNotReadThePipes() throws {
        try assertSpeechFromInsideATable(prefix: "", underTheMemoMinimum: true)
    }

    func testSpeechFromInsideATableInATextOver20KBDoesNotReadThePipes() throws {
        let prefix = String(repeating: "Plain words to pad the text out. ", count: 700) + "\n\n"
        XCTAssertGreaterThan(prefix.utf8.count, SpeechProjectionMemo.minimumBytes)
        try assertSpeechFromInsideATable(prefix: prefix, underTheMemoMinimum: false)
    }

    /// The same offset gives the same words whether the text is short or long.
    func testASpeechStartInsideATableReadsTheSameInAShortAndALongText() throws {
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"
        let short = "Intro.\n\n\(table)\n\nOutro."
        let pad = String(repeating: "Plain words to pad the text out. ", count: 700) + "\n\n"
        let long = pad + short
        let shortStart = try characterOffset(of: "| a |", in: short)
        for delta in 0..<table.count {
            let fromShort = SpeechTextNormalizer.projectForSystemSpeech(short, fromSourceOffset: shortStart + delta)
            let fromLong = SpeechTextNormalizer.projectForSystemSpeech(long, fromSourceOffset: pad.count + shortStart + delta)
            XCTAssertEqual(fromShort.text, fromLong.text, "delta \(delta)")
        }
    }
}
