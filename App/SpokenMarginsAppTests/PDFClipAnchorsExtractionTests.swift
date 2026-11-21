import XCTest
import PDFKit
import UIKit
import SessionKit
@testable import SpokenMarginsApp

/// The Now tab's card placement (#4588) against what the real PDF extractor makes, not against a hand-built document.
/// `PDFClipAnchorsTests` in SessionKit holds the table of layouts; this is the one check that the shape those rows
/// assume is the shape an import really produces: the caption is a line inside a body segment, and the float points
/// at its own text.
final class PDFClipAnchorsExtractionTests: XCTestCase {
    /// A page of 12 pt prose with a captioned table in smaller type, as a journal sets it: the caption at 9 pt, the
    /// rows at 8 pt with numbers in them. Body size is set by the prose, so the caption and rows read as table lines.
    private func pdfWithACaptionedTable() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        let caption: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let prose = [
            "Sleep and memory in adults. We measured recall after one night of sleep.",
            "Each participant studied forty word pairs in the evening and was tested the next morning.",
            "Recall was scored by two raters who did not know which group a participant belonged to.",
            "The groups differed in how they spent the hours between the study session and the test.",
        ]
        return renderer.pdfData { context in
            context.beginPage()
            for (row, text) in prose.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 72, y: 72 + Double(row) * 16), withAttributes: body)
            }
            ("Table 1. Recall by group." as NSString).draw(at: CGPoint(x: 72, y: 170), withAttributes: caption)
            let rows = ["Sleep 8.1 1.2 24", "Wake 5.9 1.6 25", "Nap 7.0 1.4 23", "Mixed 6.4 1.5 26"]
            for (row, text) in rows.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 72, y: 186 + Double(row) * 11), withAttributes: small)
            }
            for (row, text) in prose.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 72, y: 250 + Double(row) * 16), withAttributes: body)
            }
        }
    }

    func testARealImportsCaptionedTableGetsItsCardAtTheCaptionLine() throws {
        let imported = try NativePDFDocumentExtractor.extractStructured(from: pdfWithACaptionedTable())
        let document = imported.document

        let table = try XCTUnwrap(document.floats.first { $0.kind == .table },
                                  "the extractor found no table on the page, so there is nothing to place")
        let source = try XCTUnwrap(PDFClipSource(document: document, text: document.text),
                                   "a document with floats gives the Now tab a source")
        let anchors = PDFClipAnchors.make(text: document.text, source: source)

        XCTAssertEqual(anchors.count, document.floats.count, "each float of the document gets a card place")
        let anchor = try XCTUnwrap(anchors.first { $0.floatId == table.id })
        XCTAssertTrue(anchor.hasCaption, "the printed caption line is found inside the body segment")
        XCTAssertEqual(anchor.numberLabel, "Table 1")
        XCTAssertEqual(anchor.pageNumber, 1)
        XCTAssertTrue(document.text.dropFirst(anchor.anchor).hasPrefix("Table 1. Recall by group."),
                      "the card stands at the first character of the caption line, not at the table's own text")
    }

    func testTheItemDetailOfARealImportCarriesTheSourceTheCardsAreMadeFrom() throws {
        let imported = try NativePDFDocumentExtractor.extractStructured(from: pdfWithACaptionedTable())
        let document = imported.document

        let detail = ItemDetailState(id: "pdf-a", text: document.text).includingTimelineSource(document)

        XCTAssertEqual(detail.pdfClipSource, PDFClipSource(document: document, text: document.text))
        XCTAssertEqual(detail.pdfClipSource?.floats.map(\.id), document.floats.map(\.id))
        XCTAssertNil(ItemDetailState(id: "article-a", text: document.text).includingTimelineSource(nil).pdfClipSource,
                     "an item with no structured document draws no cards")
    }
}
