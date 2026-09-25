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
}
