import XCTest
@testable import SessionKit

/// #2062: arXiv 1706.03762 imported as "1 Introduction".
final class PDFItemTitleTests: XCTestCase {
    func testThePrintedTitleBeatsTheFirstOutlineHeading() {
        XCTAssertEqual(
            PDFItemTitle.choose(metadata: nil, printedTitle: "Attention Is All You Need", firstHeading: "1 Introduction"),
            "Attention Is All You Need"
        )
        for heading in ["1 Introduction", "I. INTRODUCTION", "1. Introduction", "Abstract"] {
            XCTAssertEqual(
                PDFItemTitle.choose(metadata: "", printedTitle: "Attention Is All You Need", firstHeading: heading),
                "Attention Is All You Need", heading
            )
        }
    }

    func testAMetadataTitleThatSaysSomethingStillWins() {
        XCTAssertEqual(PDFItemTitle.choose(metadata: "  Attention  Is\nAll You Need ", printedTitle: "Other", firstHeading: "1 Introduction"), "Attention Is All You Need")
    }

    func testAPlaceholderMetadataTitleIsNotATitle() {
        for placeholder in ["Microsoft Word - x.docx", "Microsoft Word - Document1", "Microsoft PowerPoint - slides.pptx",
                            "Untitled", "untitled document", "Untitled 2", "report.pdf", "paper.tex", "draft.DOCX", "", "   ", "(anonymous)"] {
            XCTAssertTrue(PDFItemTitle.isPlaceholder(placeholder), placeholder)
            XCTAssertEqual(PDFItemTitle.choose(metadata: placeholder, printedTitle: "The Real Title", firstHeading: "1 Introduction"), "The Real Title", placeholder)
        }
    }

    func testRealTitlesAreNotPlaceholders() {
        for title in ["Attention Is All You Need", "Untitled Masterpieces of the Dutch Golden Age", "Word Embeddings in Practice",
                      "The .docx Format Explained", "Document Understanding with Vision Models", "A Field Study"] {
            XCTAssertFalse(PDFItemTitle.isPlaceholder(title), title)
        }
    }

    func testWithoutAPrintedTitleTheFirstHeadingIsKept() {
        XCTAssertEqual(PDFItemTitle.choose(metadata: nil, printedTitle: nil, firstHeading: "Listening to Papers:"), "Listening to Papers:")
        XCTAssertEqual(PDFItemTitle.choose(metadata: "Microsoft Word - x.docx", printedTitle: " ", firstHeading: "Chapter One"), "Chapter One")
        XCTAssertNil(PDFItemTitle.choose(metadata: nil, printedTitle: nil, firstHeading: nil))
    }

    /// The title blocks the app's extractor reads from page 1 of arXiv 1706.03762v7 (checked on the real PDF on
    /// 2026-10-22): Google's 12 pt permission notice above the 17 pt title is display type, so it is read as a
    /// title block too, and comes first. The item was titled by the notice.
    func testTheArxivPermissionNoticeAboveTheTitleIsNotTheTitle() {
        let page1 = [
            "Provided proper attribution is provided, Google hereby grants permission to\nreproduce the tables and figures in this paper solely for use in journalistic or",
            "Attention Is All You Need",
        ]
        XCTAssertEqual(PDFItemTitle.choose(metadata: nil, printedTitles: page1, firstHeading: "1 Introduction"), "Attention Is All You Need")
    }

    func testOnlyASentenceFollowedByAnotherBlockIsPassedOver() {
        let notice = "This is the accepted version of an article that has been published in the journal of record."
        let brokenOff = "This article is distributed under the terms of the licence that allows use and"
        let cases: [([String], String?)] = [
            ([notice, "Listening to Papers:\nA Field Study"], "Listening to Papers: A Field Study"),
            ([brokenOff, "Listening to Papers"], "Listening to Papers"),
            // Long sentence-case titles that end on a word, not mid-sentence, are kept over what follows.
            (["What we learned from asking twelve researchers to listen to their reading on the commute", "A diary study"],
             "What we learned from asking twelve researchers to listen to their reading on the commute"),
            // A long title in sentence case, alone or with its subtitle, is still the title.
            (["On the dangers of stochastic parrots: can language models be too big?"],
             "On the dangers of stochastic parrots: can language models be too big?"),
            (["On the dangers of stochastic parrots: can language models be too big?", "A position paper"],
             "On the dangers of stochastic parrots: can language models be too big?"),
            // A sentence with nothing after it is all there is.
            ([notice], notice),
            // A title and its subtitle: the title.
            (["Attention Is All You Need", "Transformers for sequence transduction without recurrence or convolution at all"],
             "Attention Is All You Need"),
            ([" ", "Attention Is All You Need"], "Attention Is All You Need"),
            ([], "1 Introduction"),
        ]
        for (blocks, expected) in cases {
            XCTAssertEqual(PDFItemTitle.choose(metadata: nil, printedTitles: blocks, firstHeading: "1 Introduction"), expected, "\(blocks)")
        }
    }

    func testPlaceholderNeighbours() {
        for placeholder in ["Untitled-1", "Untitled - 3", "Microsoft Word – x.docx", "Microsoft Word — x.docx", "PowerPoint Presentation", "Slide 1"] {
            XCTAssertTrue(PDFItemTitle.isPlaceholder(placeholder), placeholder)
        }
        for title in ["Untitled-1 and Other Lost Works", "Slide Rules and Their Makers", "PowerPoint Presentations That Work"] {
            XCTAssertFalse(PDFItemTitle.isPlaceholder(title), title)
        }
    }

    func testATitleSplitOverTwoLinesIsOneTitle() {
        XCTAssertEqual(
            PDFItemTitle.choose(metadata: nil, printedTitle: "Listening to Papers:\n  A Field Study", firstHeading: "1 Introduction"),
            "Listening to Papers: A Field Study"
        )
    }

    // MARK: #2807 - an outlined PDF with no Abstract label

    private func line(_ text: String, _ size: Double) -> PDFItemTitle.PageLine { .init(text: text, pointSize: size) }

    /// "Collected Stories / Edited by Example Author / Contents" imported as "Story 1", its first bookmark.
    func testAStoryCollectionIsTitledByPageOneNotItsFirstBookmark() {
        let page1 = [line("Collected Stories", 28), line("Edited by Example Author", 14), line("Contents", 18),
                     line("Story 1 .......... 3", 11), line("Story 2 .......... 9", 11)]
        let title = PDFItemTitle.displayTitle(onPageOne: page1, bodySize: 11)
        XCTAssertEqual(title, "Collected Stories")
        XCTAssertEqual(PDFItemTitle.choose(metadata: nil, printedTitles: title.map { [$0] } ?? [], firstHeading: "Story 1"), "Collected Stories")
    }

    func testAMetadataTitleStillBeatsThePageOneTitle() {
        XCTAssertEqual(
            PDFItemTitle.choose(metadata: "Stories of the Coast", printedTitles: ["Collected Stories"], firstHeading: "Story 1"),
            "Stories of the Coast"
        )
    }

    func testDisplayTitleNeighbours() {
        let cases: [(String, [PDFItemTitle.PageLine], String?)] = [
            ("a title over two lines is one title",
             [line("The Collected Stories", 28), line("of Example Author", 28), line("Contents", 18), line("Story 1", 11)],
             "The Collected Stories of Example Author"),
            ("a contents label set larger than the title is not the title",
             [line("Stories", 20), line("Table of Contents", 26), line("Story 1", 11)], "Stories"),
            ("a numbered section label is not the title",
             [line("1 Introduction", 22), line("Body text of the first section goes here.", 11)], nil),
            ("a title that starts with a number is kept",
             [line("21 Lessons for Listening", 26), line("Contents", 18)], "21 Lessons for Listening"),
            ("a single heading equal to its first bookmark",
             [line("Chapter One", 24), line("It began on a Tuesday, as these things do.", 11)], "Chapter One"),
            ("no display type on page 1",
             [line("It began on a Tuesday, as these things do.", 11), line("Nobody remembered why.", 11)], nil),
            ("a page number in display type is not a title",
             [line("12", 24), line("Body text of the page.", 11)], nil),
            ("empty page", [], nil),
            ("a notice in display type is not a title",
             [line("Provided proper attribution is provided, Google hereby grants permission to reproduce the tables and figures in this paper solely for use in journalistic or", 14),
              line("Body text.", 11)], nil),
            ("an editor line set as large as the title is a credit, not part of it",
             [line("Collected Stories", 24), line("Edited by Example Author", 24), line("Contents", 18)], "Collected Stories"),
            ("a copyright line in display type is skipped",
             [line("© 2026 Example Press", 24), line("Collected Stories", 24)], "Collected Stories"),
            ("a part or chapter label is not the title",
             [line("Part II", 30), line("The Long Way Home", 20), line("Chapter 3", 14)], "The Long Way Home"),
        ]
        for (name, lines, expected) in cases {
            XCTAssertEqual(PDFItemTitle.displayTitle(onPageOne: lines, bodySize: 11), expected, name)
        }
    }

    func testStructuralLabels() {
        for label in ["Contents", "TABLE OF CONTENTS", "Table of Contents", "1 Introduction", "I. INTRODUCTION", "1. Introduction",
                      "Preface", "Foreword", "Acknowledgements", "Acknowledgments", "Dedication", "About the Author",
                      "Part II", "Chapter 3", "Volume 2"] {
            XCTAssertTrue(PDFItemTitle.isStructuralLabel(label), label)
        }
        for title in ["Contents of the Mind", "Introduction to Algorithms", "Dedication and Other Stories", "The Preface Problem", "Summary Statistics Done Right", "Part of the Problem", "Chapter and Verse"] {
            XCTAssertFalse(PDFItemTitle.isStructuralLabel(title), title)
        }
    }
}
