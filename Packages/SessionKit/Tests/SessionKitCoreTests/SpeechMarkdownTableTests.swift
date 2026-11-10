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
}
