import XCTest
import PDFKit
import UIKit
import SessionKit
import SessionKitSharing
@testable import SpokenMarginsApp

final class PDFStructuredTextExtractorTests: XCTestCase {

    func testPDFDownloadDatesDoNotChangePreparedTextIdentityButBodyDatesDo() throws {
        func extracted(stamp: String, body: String) throws -> String {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let data = renderer.pdfData { context in
                context.beginPage()
                (stamp as NSString).draw(at: CGPoint(x: 30, y: 25), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                (body as NSString).draw(in: CGRect(x: 40, y: 200, width: 520, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
            return try PDFStructuredTextExtractor.markdown(from: XCTUnwrap(PDFDocument(data: data)))
        }
        let body = "Research findings. The experiment began on 2026-09-01. Its results are meaningful."
        let first = try extracted(stamp: "Downloaded on 2026-09-21", body: body)
        let second = try extracted(stamp: "Downloaded on 2026-09-22", body: body)
        XCTAssertFalse(first.contains("Downloaded"))
        XCTAssertEqual(PortableArticleAnchorResolver.normalizedContentSHA256(first), PortableArticleAnchorResolver.normalizedContentSHA256(second))
        let changed = try extracted(stamp: "Downloaded on 2026-09-22", body: body.replacingOccurrences(of: "2026-09-01", with: "2026-09-02"))
        XCTAssertNotEqual(PortableArticleAnchorResolver.normalizedContentSHA256(first), PortableArticleAnchorResolver.normalizedContentSHA256(changed))
        let quote = "Its results are meaningful."
        let anchor = PortableAnchorEvidence(anchorType: .text, exactText: quote)
        let resolution = PortableArticleAnchorResolver.resolve(anchor: anchor, in: second, expectedExactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(first))
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertNotNil(resolution.localStartChar)
        XCTAssertFalse(PDFStructuredTextExtractor.isDownloadStamp("The dataset was downloaded on 2026-09-22 for our experiment."))
    }

    func testDownloadStampSharingAFooterLineWithThePageNumberIsNotRead() throws {
        // #162: PDFKit merges "Downloaded on …" and the page number on one baseline.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let footer: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let data = renderer.pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("Part \(page): Why listen with a pencil" as NSString).draw(
                    in: CGRect(x: 72, y: 100, width: 468, height: 400),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                ("Downloaded on 25 September 2026" as NSString).draw(at: CGPoint(x: 72, y: 740), withAttributes: footer)
                ("\(page)" as NSString).draw(at: CGPoint(x: 530, y: 740), withAttributes: footer)
            }
        }
        let markdown = try PDFStructuredTextExtractor.markdown(from: XCTUnwrap(PDFDocument(data: data)))
        XCTAssertFalse(markdown.contains("Downloaded"), markdown)
        XCTAssertTrue(markdown.contains("Why listen with a pencil"))

        XCTAssertTrue(PDFStructuredTextExtractor.isDownloadStamp("Downloaded on 25 September 2026 3"))
        XCTAssertTrue(PDFStructuredTextExtractor.isDownloadStamp("Downloaded on 2026-09-21 Page 3 of 12"))
        XCTAssertTrue(PDFStructuredTextExtractor.isDownloadStamp("iv Downloaded on 25 September 2026"))
        XCTAssertFalse(PDFStructuredTextExtractor.isDownloadStamp("Downloaded on 25 September 2026 3 times by readers"))
    }

    // MARK: Extraction v2 (C1 M3)

    func testV2ReadsTheAppendixAfterAnAuthorYearReferenceList() {
        // v1 cut everything after the references heading (#215) and missed author-year lists.
        var lines = [
            StructuredDocumentLine(text: "Discussion", role: .heading, level: 2),
            StructuredDocumentLine(text: "The effect held.", role: .body),
            StructuredDocumentLine(text: "References", role: .heading, level: 2),
            StructuredDocumentLine(text: "Agarwal A, Halvorson LM (2005) Pituitary peptides. J Neurosci 72:451.", role: .body),
            StructuredDocumentLine(text: "Abdul-Hay, S. O., and Thatcher, G. R. (2009). Selective modulation.", role: .body),
            StructuredDocumentLine(text: "[3] C. Writer. Reading and listening. 2020.", role: .body),
            StructuredDocumentLine(text: "Lee K, Park J (2019) Sleep. Nature 1:2.", role: .body),
            StructuredDocumentLine(text: "Appendix A", role: .heading, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.heading, .body, .reference, .reference, .reference, .reference, .reference, .heading, .body])
    }

    func testV2DoesNotTakeAProseMentionOfReferencesForAList() {
        var lines = [
            StructuredDocumentLine(text: "References", role: .body),
            StructuredDocumentLine(text: "are listed at the end of each chapter, as in earlier editions.", role: .body),
            StructuredDocumentLine(text: "The method is described below.", role: .body),
        ]
        PDFStructuredTextExtractor.labelReferenceLists(&lines)
        XCTAssertEqual(lines.map(\.role), [.body, .body, .body])
    }

    func testV2RecognisesTitlePageAuthorsAndTableCaptions() {
        XCTAssertTrue(PDFStructuredTextExtractor.looksLikeAuthorList("Ada Example1, Ben Sample2 and C. D. Third*"))
        XCTAssertFalse(PDFStructuredTextExtractor.looksLikeAuthorList("1Department of Ecology, University of Lausanne, CH-1015 Lausanne"))
        XCTAssertFalse(PDFStructuredTextExtractor.looksLikeAuthorList("We asked twelve researchers to listen to papers."))
        XCTAssertTrue(PDFStructuredTextExtractor.isTableCaption("Table 3"))
        XCTAssertTrue(PDFStructuredTextExtractor.isTableCaption("Table 2. Baseline characteristics"))
        XCTAssertFalse(PDFStructuredTextExtractor.isTableCaption("Table 2 shows the results."))
        XCTAssertTrue(PDFStructuredTextExtractor.isFigureCaption("Fig. 3 (a) Survival by arm."))
        XCTAssertTrue(PDFStructuredTextExtractor.isFigureCaption("FIGURE 1. Study design"))
        XCTAssertFalse(PDFStructuredTextExtractor.isFigureCaption("Figure 3 shows a decline."))
    }

    func testV2JoinsTheFragmentsOfAMultiLineEquationButNotProse() {
        var lines = [
            StructuredDocumentLine(text: "𝑓(𝑥) = ∑ 𝑎ᵢ", role: .equation, pageIndex: 1),
            StructuredDocumentLine(text: "(3)", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "𝑔(𝑥) = ∫ 𝑓", role: .equation, pageIndex: 1),
            StructuredDocumentLine(text: "where both terms", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "ℎ = 𝑓 ∘ 𝑔", role: .equation, pageIndex: 1),
        ]
        PDFStructuredTextExtractor.joinEquationFragments(&lines)
        XCTAssertEqual(lines.map(\.role), [.equation, .equation, .equation, .body, .equation])
    }
}
