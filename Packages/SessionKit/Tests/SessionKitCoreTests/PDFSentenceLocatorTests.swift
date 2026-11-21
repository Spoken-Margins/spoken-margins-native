import Foundation
import XCTest
@testable import SessionKit

/// #4338 PR 3 (the host-testable half): finding a Margin's sentence in the text of a PDF's pages. Page strings are
/// written the way PDFKit gives them: hard line breaks, hyphenated line ends, curly quotes, doubled spaces.
final class PDFSentenceLocatorTests: XCTestCase {
    private let long = "We measured sleep in two hundred adults across the whole of one winter."

    private func locate(
        _ sentence: String, hint: Int?, pages: [String?], preceding: String = ""
    ) -> PDFSentenceLocator.Placement {
        PDFSentenceLocator.locate(
            sentence: sentence, hintedPage: hint, preceding: preceding, pageCount: pages.count,
            pageText: { $0 < pages.count ? pages[$0] : nil })
    }

    /// The text a placement highlights, read back out of its page the way the PDFKit side will.
    private func highlighted(_ placement: PDFSentenceLocator.Placement, pages: [String?]) -> (page: Int, text: String, whole: Bool)? {
        guard case .highlight(let page, let range, let whole) = placement, let text = pages[page] else { return nil }
        let characters = Array(text)
        return (page, String(characters[range]), whole)
    }

    // MARK: - The Design's neighbouring inputs. Each row states the page and the text it must highlight.

    private struct Row {
        var name: String
        var sentence: String
        var hint: Int?
        var pages: [String?]
        var preceding = ""
        /// nil: a page note on `notePage`.
        var expectPage: Int?
        var expectText: String?
        var expectWhole = true
        var notePage = 0
    }

    private var rows: [Row] {
        let sentence = long
        return [
            Row(name: "plain", sentence: sentence, hint: 0,
                pages: ["Intro text here. \(sentence) More after."], expectPage: 0, expectText: sentence),
            Row(name: "split across lines", sentence: sentence, hint: 0,
                pages: ["Intro. We measured sleep in two hundred\nadults across the whole of\none winter. After."],
                expectPage: 0, expectText: "We measured sleep in two hundred\nadults across the whole of\none winter."),
            Row(name: "doubled spaces and a tab", sentence: sentence, hint: 0,
                pages: ["We  measured sleep in two\thundred adults across   the whole of one winter."],
                expectPage: 0, expectText: "We  measured sleep in two\thundred adults across   the whole of one winter."),
            Row(name: "hyphenated at a line end", sentence: sentence, hint: 0,
                pages: ["We measured sleep in two hun-\ndred adults across the whole of one winter."],
                expectPage: 0, expectText: "We measured sleep in two hun-\ndred adults across the whole of one winter."),
            Row(name: "soft hyphen inside a word", sentence: sentence, hint: 0,
                pages: ["We measured sleep in two hun\u{00AD}dred adults across the whole of one winter."],
                expectPage: 0, expectText: "We measured sleep in two hun\u{00AD}dred adults across the whole of one winter."),
            Row(name: "a real hyphen the document spells and the page wraps", sentence: "The well-known effect of light on sleep was seen again in every one of the groups.",
                hint: 0, pages: ["The well-\nknown effect of light on sleep was seen again in every one of the groups."],
                expectPage: 0, expectText: "The well-\nknown effect of light on sleep was seen again in every one of the groups."),
            Row(name: "curly quotes against straight", sentence: "She said \"it isn't over\" and we kept counting the nights of sleep that week.",
                hint: 0, pages: ["She said \u{201C}it isn\u{2019}t over\u{201D} and we kept counting the nights of sleep that week."],
                expectPage: 0, expectText: "She said \u{201C}it isn\u{2019}t over\u{201D} and we kept counting the nights of sleep that week."),
            Row(name: "case differs", sentence: sentence.uppercased(), hint: 0,
                pages: [sentence], expectPage: 0, expectText: sentence),
            Row(name: "NFD é in the page, NFC in the document", sentence: "The caf\u{00E9} study of sleep gave the same result in every one of the groups we saw.",
                hint: 0, pages: ["The cafe\u{0301} study of sleep gave the same result in every one of the groups we saw."],
                expectPage: 0, expectText: "The cafe\u{0301} study of sleep gave the same result in every one of the groups we saw."),
            Row(name: "the page before the hint holds it", sentence: sentence, hint: 1,
                pages: ["Opening. \(sentence)", "Something else entirely.", "Third page."], expectPage: 0, expectText: sentence),
            Row(name: "the page after the hint holds it", sentence: sentence, hint: 1,
                pages: ["Opening.", "Something else.", sentence], expectPage: 2, expectText: sentence),
            Row(name: "two pages away is too far", sentence: sentence, hint: 0,
                pages: ["Opening.", "Middle.", sentence], expectPage: nil, expectText: nil, expectWhole: true, notePage: 0),
            Row(name: "the hinted page beats a neighbour that also has it", sentence: sentence, hint: 1,
                pages: [sentence, sentence, "x"], expectPage: 1, expectText: sentence),
            Row(name: "across a page break: first page only, by its start", sentence: "We measured sleep in two hundred adults across the whole of one winter and then again in spring.",
                hint: 0, pages: ["Opening. We measured sleep in two hundred adults across the whole of one winter", "and then again in spring. Closing."],
                expectPage: 0, expectText: "We measured sleep in two hundred adults across the whole of one winter", expectWhole: false),
            Row(name: "across columns: another column's lines in the middle", sentence: "We measured sleep in two hundred adults across the whole of one winter and then again in spring.",
                hint: 0, pages: ["We measured sleep in two hundred adults across the whole of\nTable 2 Mean hours by group\nGroup A 7.1 Group B 6.9\none winter and then again in spring."],
                expectPage: 0, expectText: "We measured sleep in two hundred adults across the whole of", expectWhole: false),
            Row(name: "the same sentence twice on a page: the one after the Margin's own words", sentence: sentence, hint: 0,
                pages: ["First we read the methods of the old study. \(sentence) Then a long table. Later, after the second trial began, \(sentence) End."],
                preceding: "Later, after the second trial began,", expectPage: 0, expectText: sentence),
            Row(name: "a scanned page with no text", sentence: sentence, hint: 0, pages: [nil], expectPage: nil, expectText: nil, notePage: 0),
            Row(name: "a page of white space only", sentence: sentence, hint: 1, pages: ["x", " \n \n"], expectPage: nil, expectText: nil, notePage: 1),
            Row(name: "the sentence is nowhere", sentence: sentence, hint: 0, pages: ["Nothing alike here at all."], expectPage: nil, expectText: nil),
            Row(name: "a short sentence found only whole", sentence: "It was cold.", hint: 0, pages: ["It was cold, they said."], expectPage: nil, expectText: nil),
            Row(name: "a short sentence found whole", sentence: "It was cold.", hint: 0, pages: ["Day one. It was cold. Day two."], expectPage: 0, expectText: "It was cold."),
            Row(name: "a prefix too short to trust is refused", sentence: "In the beginning there was a long and winding road to the sea that nobody walked.",
                hint: 0, pages: ["In the beginning there was a flood. Elsewhere."], expectPage: nil, expectText: nil),
            Row(name: "not inside a longer word at the start", sentence: "In the end the whole winter of sleep was measured in two hundred adults.",
                hint: 0, pages: ["Within the end the whole winter of sleep was measured in two hundred adults."], expectPage: nil, expectText: nil),
            Row(name: "a start that stops inside a longer word is not that word", sentence: "We measured the sleep of two hundred adults across the whole of one winter and again in spring.",
                hint: 0, pages: ["We measured the sleep of two hundred adults across the whole of one winter and again in springtime."],
                expectPage: 0, expectText: "We measured the sleep of two hundred adults across the whole of one winter and again in", expectWhole: false),
            Row(name: "a soft hyphen before the line break", sentence: sentence, hint: 0,
                pages: ["We measured sleep in two hun\u{00AD}\ndred adults across the whole of one winter."],
                expectPage: 0, expectText: "We measured sleep in two hun\u{00AD}\ndred adults across the whole of one winter."),
            Row(name: "a prefix may not stop inside the page's longer word", sentence: "We measured sleep in two hundred adults across the whole of one winter and then again in spring.",
                hint: 0, pages: ["We measured sleep in two hundred adults across the whole of one winter and then against all odds we stopped."],
                expectPage: 0, expectText: "We measured sleep in two hundred adults across the whole of one winter and then", expectWhole: false),
            Row(name: "a short sentence is not the tail of a longer word", sentence: "It was cold.", hint: 0, pages: ["Wit was cold."], expectPage: nil, expectText: nil),
            Row(name: "dashes the page lacks do not match", sentence: "Sleep - or the lack of it - shaped the answers given by every one of the groups.",
                hint: 0, pages: ["Sleep or the lack of it shaped the answers given by every one of the groups."], expectPage: nil, expectText: nil),
            Row(name: "no hint searches every page in order", sentence: sentence, hint: nil, pages: ["a", "b", sentence], expectPage: 2, expectText: sentence),
            Row(name: "a hint past the last page falls on the last", sentence: sentence, hint: 9, pages: ["a", sentence], expectPage: 1, expectText: sentence, notePage: 1),
            Row(name: "an empty sentence is a page note", sentence: "", hint: 0, pages: ["anything"], expectPage: nil, expectText: nil),
            Row(name: "a dash between spaces is kept, not joined", sentence: "Sleep - or the lack of it - shaped the answers given by every one of the groups.",
                hint: 0, pages: ["Sleep - or the lack of it - shaped the answers given by every one of the groups."],
                expectPage: 0, expectText: "Sleep - or the lack of it - shaped the answers given by every one of the groups."),
        ]
    }

    func testTheNeighbouringInputTable() {
        var misplaced: [String] = []
        for row in rows {
            let placement = locate(row.sentence, hint: row.hint, pages: row.pages, preceding: row.preceding)
            if let expectedPage = row.expectPage, let expectedText = row.expectText {
                guard let got = highlighted(placement, pages: row.pages) else {
                    misplaced.append("\(row.name): wanted a highlight, got \(placement)")
                    continue
                }
                if got.page != expectedPage || got.text != expectedText || got.whole != row.expectWhole {
                    misplaced.append("\(row.name): page \(got.page) '\(got.text)' whole \(got.whole)")
                }
            } else if placement != .pageNote(page: row.notePage) {
                misplaced.append("\(row.name): wanted a note on page \(row.notePage), got \(placement)")
            }
        }
        XCTAssertEqual(misplaced, [], "misplaced rows (the PR states this count)")
    }

    // MARK: - The pieces

    /// The table checks the text, which is the same for both copies; this checks which copy.
    func testTwoCopiesOnAPageAreToldApartByTheWordsBeforeThem() {
        let page = "Early on, before the study began, \(long) Then a table. Later, after the second trial began, \(long) End."
        let characters = Array(page)
        func start(of marker: String) -> Int {
            let before = page.components(separatedBy: marker)[0]
            return before.count + marker.count
        }
        let first = start(of: "before the study began, ")
        let second = start(of: "after the second trial began, ")
        for (preceding, wanted) in [("Early on, before the study began,", first), ("Later, after the second trial began,", second)] {
            guard case .highlight(_, let range, true) = locate(long, hint: 0, pages: [page], preceding: preceding) else {
                return XCTFail("expected a whole-sentence highlight")
            }
            XCTAssertEqual(range.lowerBound, wanted, "preceding: \(preceding)")
            XCTAssertEqual(String(characters[range]), long)
        }
        // With nothing to tell them apart, the earlier copy.
        guard case .highlight(_, let range, _) = locate(long, hint: 0, pages: [page]) else { return XCTFail("expected a highlight") }
        XCTAssertEqual(range.lowerBound, first)
    }

    func testNormalizingKeepsWhereEachCharacterCameFrom() {
        // Source offsets: A0 space1 space2 \u{201C}3 B4 \u{201D}5 hyphen6 newline7 C8.
        let folded = PDFSentenceLocator.Normalized("A  \u{201C}B\u{201D}-\nC")
        // One space for the two; quotes made straight; the hyphen stays (it follows a quote, not a letter).
        XCTAssertEqual(String(folded.characters), "a \"b\"- c")
        XCTAssertEqual(folded.original, [0, 1, 3, 4, 5, 6, 7, 8])
    }

    func testAHyphenInsideOrAtTheEndOfAWordGoesAndTheOffsetsStillPointAtTheOriginal() {
        let folded = PDFSentenceLocator.Normalized("re-\n  enter, well-known")
        XCTAssertEqual(String(folded.characters), "reenter, wellknown")
        XCTAssertEqual(folded.original.first, 0)
        XCTAssertEqual(folded.original[2], 6, "the 'e' after the line break")
    }

    func testWhiteSpaceAtTheEndsIsDropped() {
        XCTAssertEqual(String(PDFSentenceLocator.Normalized("  \n a b \t ").characters), "a b")
        XCTAssertEqual(PDFSentenceLocator.Normalized("   ").characters, [])
    }

    func testOccurrencesFindsOverlapsAndNothing() {
        XCTAssertEqual(PDFSentenceLocator.occurrences(of: Array("aa"), in: Array("aaaa")), [0, 1, 2])
        XCTAssertEqual(PDFSentenceLocator.occurrences(of: Array("abc"), in: Array("ab")), [])
        XCTAssertEqual(PDFSentenceLocator.occurrences(of: [], in: Array("ab")), [])
        XCTAssertEqual(PDFSentenceLocator.occurrences(of: Array("ab"), in: Array("xabxab")), [1, 4])
    }

    func testPrefixesAreWholeWordsLongestFirstAndNeedEightWordsAndFortyCharacters() {
        let target = Array("alpha bravo charlie delta echo foxtrot golf hotel india juliet")
        let found = PDFSentenceLocator.prefixes(of: target)?.map { String($0) }
        XCTAssertEqual(found?.first, "alpha bravo charlie delta echo foxtrot golf hotel india")
        XCTAssertEqual(found?.last, "alpha bravo charlie delta echo foxtrot golf hotel")
        XCTAssertNil(PDFSentenceLocator.prefixes(of: Array("alpha bravo charlie delta echo foxtrot golf hotel")), "exactly eight words is the whole sentence")
        // Nine words whose first eight are 39 characters: one short of the character floor.
        XCTAssertNil(PDFSentenceLocator.prefixes(of: Array("one two three four five six seven eight nine")))
        // Nine words, but the eight-word start is under 40 characters.
        XCTAssertNil(PDFSentenceLocator.prefixes(of: Array("a b c d e f g h i")))
    }

    func testTheOrderOfPagesToLook() {
        XCTAssertEqual(PDFSentenceLocator.searchOrder(3, pageCount: 10), [3, 2, 4])
        XCTAssertEqual(PDFSentenceLocator.searchOrder(0, pageCount: 10), [0, 1])
        XCTAssertEqual(PDFSentenceLocator.searchOrder(9, pageCount: 10), [9, 8])
        XCTAssertEqual(PDFSentenceLocator.searchOrder(40, pageCount: 3), [2, 1])
        XCTAssertEqual(PDFSentenceLocator.searchOrder(nil, pageCount: 3), [0, 1, 2])
        XCTAssertEqual(PDFSentenceLocator.searchOrder(0, pageCount: 0), [])
        XCTAssertEqual(PDFSentenceLocator.noteHome(-4, pageCount: 3), 0)
    }

    func testAZeroPageDocumentGivesANoteOnPageZero() {
        XCTAssertEqual(locate(long, hint: 0, pages: []), .pageNote(page: 0))
    }

    /// A 300-page paper: only the pages near the hint are read, so a placement does not cost the whole document.
    func testOnlyThePagesNearTheHintAreRead() {
        var asked: [Int] = []
        let placement = PDFSentenceLocator.locate(sentence: long, hintedPage: 150, preceding: "", pageCount: 300) { page in
            asked.append(page)
            return page == 151 ? self.long : "filler"
        }
        XCTAssertEqual(asked.sorted(), [149, 150, 151])
        XCTAssertEqual(placement, .highlight(page: 151, range: 0..<long.count, wholeSentence: true))
    }

    /// Very long sentences and pages stay fast: one pass, not a quadratic search.
    func testALongPageOfRepeatedWordsIsOnePass() {
        let page = String(repeating: "sleep ", count: 60_000)
        let sentence = String(repeating: "sleep ", count: 600) + "never"
        let started = Date()
        let placement = locate(sentence, hint: 0, pages: [page])
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.4 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a quadratic search over the long page.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        if case .highlight(_, _, let whole) = placement { XCTAssertFalse(whole) } else { XCTFail("the start of it is on the page") }
    }
}
