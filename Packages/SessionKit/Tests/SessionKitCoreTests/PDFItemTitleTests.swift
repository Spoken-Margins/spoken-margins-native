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

    func testATitleSplitOverTwoLinesIsOneTitle() {
        XCTAssertEqual(
            PDFItemTitle.choose(metadata: nil, printedTitle: "Listening to Papers:\n  A Field Study", firstHeading: "1 Introduction"),
            "Listening to Papers: A Field Study"
        )
    }
}
