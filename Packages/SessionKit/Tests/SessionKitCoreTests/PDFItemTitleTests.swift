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
}
