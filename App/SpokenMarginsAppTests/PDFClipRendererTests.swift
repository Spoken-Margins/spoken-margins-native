import XCTest
import PDFKit
import UIKit
import SessionKit
@testable import SpokenMarginsApp

/// The pictures cut from a PDF's tables and figures at import (#3895): the right part of the page, the right way up.
final class PDFClipRendererTests: XCTestCase {
    private let pageWidth = 612.0, pageHeight = 792.0

    /// One page, white, with a black block 200 x 100 pt whose top left is 100 pt from the page's top and left.
    private func pageWithBlackBlock() throws -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let data = renderer.pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 200, height: 100))
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    /// A region given in points from the page's top left, as fractions from its bottom left.
    private func float(_ id: String, left: Double, top: Double, width: Double, height: Double, page: Int = 0) -> StructuredDocument.Float {
        StructuredDocument.Float(
            id: id, kind: .table, label: nil, pageIndex: page,
            bounds: PDFNormalizedRect(
                x: left / pageWidth, y: (pageHeight - top - height) / pageHeight,
                width: width / pageWidth, height: height / pageHeight),
            captionSegmentId: nil, textSegmentId: "s1")
    }

    /// The mean brightness (0 black, 1 white) of the rows of a JPEG between two fractions of its height, from the top.
    private func brightness(_ data: Data, fromRow top: Double = 0, toRow bottom: Double = 1) throws -> Double {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let first = Int(Double(height) * top), last = max(first + 1, Int(Double(height) * bottom))
        var sum = 0.0, count = 0.0
        for y in first..<min(last, height) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                sum += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 765
                count += 1
            }
        }
        return sum / count
    }

    func testAClipIsTheRegionOfThePageItNamesAndTheRightWayUp() throws {
        let document = try pageWithBlackBlock()
        let floats = [
            float("inside", left: 110, top: 110, width: 180, height: 80),
            float("below-it", left: 110, top: 250, width: 180, height: 80),
            float("beside-it", left: 400, top: 110, width: 180, height: 80),
            float("mirrored", left: 110, top: pageHeight - 190, width: 180, height: 80),
            // Starts 50 pt above the block and ends 50 pt into it: white on top, black below.
            float("straddling", left: 110, top: 50, width: 180, height: 100),
        ]

        let clips = PDFClipRenderer.clips(for: floats, in: document)

        XCTAssertEqual(Set(clips.keys), Set(floats.map(\.id)))
        XCTAssertLessThan(try brightness(try XCTUnwrap(clips["inside"])), 0.1, "the block")
        XCTAssertGreaterThan(try brightness(try XCTUnwrap(clips["below-it"])), 0.95, "paper below the block")
        XCTAssertGreaterThan(try brightness(try XCTUnwrap(clips["beside-it"])), 0.95, "paper beside it")
        XCTAssertGreaterThan(try brightness(try XCTUnwrap(clips["mirrored"])), 0.95, "the block's place upside down is paper")
        let straddling = try XCTUnwrap(clips["straddling"])
        XCTAssertGreaterThan(try brightness(straddling, fromRow: 0, toRow: 0.4), 0.9, "the top of the clip is the paper above")
        XCTAssertLessThan(try brightness(straddling, fromRow: 0.6, toRow: 1), 0.15, "its bottom is the block")
    }

    func testAClipIsAJPEGOfTheRegionsShapeAndNeverBiggerThanTheLimit() throws {
        let document = try pageWithBlackBlock()
        let clips = PDFClipRenderer.clips(for: [
            float("wide", left: 50, top: 100, width: 500, height: 100),
            float("whole-page", left: 6, top: 8, width: 600, height: 776),
        ], in: document)

        for (id, data) in clips {
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "\(id) is a JPEG")
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertLessThanOrEqual(Double(max(image.width, image.height)), PDFClipGeometry.maximumClipPixels, id)
        }
        let wide = try XCTUnwrap(UIImage(data: try XCTUnwrap(clips["wide"]))?.cgImage)
        XCTAssertEqual(Double(wide.width) / Double(wide.height), 5, accuracy: 0.1, "500 x 100 pt")
    }

    func testAFloatOnAPageThePDFDoesNotHaveOrWithNoAreaGetsNoClip() throws {
        let document = try pageWithBlackBlock()
        let clips = PDFClipRenderer.clips(for: [
            float("no-such-page", left: 110, top: 110, width: 180, height: 80, page: 3),
            float("no-area", left: 110, top: 110, width: 0, height: 80),
            float("fine", left: 110, top: 110, width: 180, height: 80),
        ], in: document)

        XCTAssertEqual(Set(clips.keys), ["fine"])
    }

    func testNoMoreThanTheLimitOfClipsAreCut() throws {
        let document = try pageWithBlackBlock()
        let floats = (0..<(PDFClipLocator.maximumFloatsPerDocument + 5)).map {
            float("float-\($0)", left: 110, top: 110, width: 180, height: 80)
        }
        XCTAssertEqual(PDFClipRenderer.clips(for: floats, in: document).count, PDFClipLocator.maximumFloatsPerDocument)
    }

    /// The import itself: whatever regions the extractor puts in the document of a PDF with a captioned table, each has
    /// a picture and no other id does. (Which lines make a table is the extractor's own tests' business.)
    func testExtractionCutsOneClipForEachFloatItPutInTheDocument() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Sleep and memory in adults. We measured recall after one night of sleep." as NSString)
                .draw(in: CGRect(x: 72, y: 72, width: 468, height: 60), withAttributes: body)
            ("Table 1. Recall by group." as NSString).draw(at: CGPoint(x: 72, y: 160), withAttributes: body)
            for (row, text) in ["Group | Mean | SD", "Sleep | 8.1 | 1.2", "Wake | 5.9 | 1.6", "Nap | 7.0 | 1.4"].enumerated() {
                (text as NSString).draw(at: CGPoint(x: 72, y: 190 + Double(row) * 16), withAttributes: body)
            }
        }

        let imported = try NativePDFDocumentExtractor.extractStructured(from: data)

        XCTAssertEqual(Set(imported.clips.keys), Set(imported.document.floats.map(\.id)),
                       "every region in the document has a picture, and nothing else has")
    }
}
