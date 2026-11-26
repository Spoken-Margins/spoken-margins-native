@testable import SessionKit
import XCTest

/// Where a document's text starts and ends on a typical page (#4587).
final class PDFTextAreaTests: XCTestCase {
    /// A page of `lines` lines whose highest line ends at `top` and whose lowest starts at `bottom`.
    private func page(top: Double, bottom: Double, lines: Int = 6) -> [PDFNormalizedRect] {
        (0..<lines).map { index in
            let step = lines > 1 ? (top - bottom - 0.02) / Double(lines - 1) : 0
            return PDFNormalizedRect(x: 0.1, y: bottom + Double(index) * step, width: 0.8, height: 0.02)
        }
    }

    func testTheTopIsTheSeventyFifthPercentileOfPageTopsAndTheBottomTheTwentyFifthOfPageBottoms() throws {
        let pages = [(0.90, 0.08), (0.92, 0.07), (0.94, 0.06), (0.96, 0.05)].map { page(top: $0.0, bottom: $0.1) }
        let area = try XCTUnwrap(PDFFigureCaptionLocator.textArea(pages: pages))
        // Nearest rank: N = 4, index ceil(0.75 * 4) - 1 = 2 of the tops, ceil(0.25 * 4) - 1 = 0 of the bottoms.
        XCTAssertEqual(area.top, 0.94, accuracy: 1e-9)
        XCTAssertEqual(area.bottom, 0.05, accuracy: 1e-9)
    }

    func testNearestRankWithFivePages() throws {
        let pages = [0.90, 0.91, 0.92, 0.93, 0.99].map { page(top: $0, bottom: 0.1) }
            .enumerated().map { index, lines in lines.map { PDFNormalizedRect(x: $0.x, y: $0.y - Double(index) * 0.01, width: $0.width, height: $0.height) } }
        let area = try XCTUnwrap(PDFFigureCaptionLocator.textArea(pages: pages))
        // Tops after the shift are 0.90, 0.90, 0.90, 0.90, 0.95 and bottoms 0.10, 0.09, 0.08, 0.07, 0.06:
        // index ceil(3.75) - 1 = 3 of the sorted tops, and ceil(1.25) - 1 = 1 of the sorted bottoms.
        XCTAssertEqual(area.top, 0.90, accuracy: 1e-9)
        XCTAssertEqual(area.bottom, 0.07, accuracy: 1e-9)
    }

    func testPagesUnderFiveLinesAreSkipped() throws {
        let full = [page(top: 0.9, bottom: 0.1), page(top: 0.9, bottom: 0.1), page(top: 0.9, bottom: 0.1)]
        let short = [page(top: 0.5, bottom: 0.4, lines: 4), page(top: 0.4, bottom: 0.3, lines: 1)]
        let area = try XCTUnwrap(PDFFigureCaptionLocator.textArea(pages: full + short))
        XCTAssertEqual(area.top, 0.9, accuracy: 1e-9, "the short pages do not pull the top in")
        XCTAssertEqual(area.bottom, 0.1, accuracy: 1e-9)
    }

    func testFewerThanThreeCountedPagesGivesNoTextArea() {
        XCTAssertNil(PDFFigureCaptionLocator.textArea(pages: []))
        XCTAssertNil(PDFFigureCaptionLocator.textArea(pages: [page(top: 0.9, bottom: 0.1), page(top: 0.9, bottom: 0.1)]))
        XCTAssertNil(PDFFigureCaptionLocator.textArea(pages: [page(top: 0.9, bottom: 0.1), page(top: 0.9, bottom: 0.1),
                                                              page(top: 0.9, bottom: 0.1, lines: 4)]),
                     "a third page with four lines does not count")
    }

    func testOneStrayHighLineOnOnePageDoesNotMoveTheTop() throws {
        var pages = (0..<4).map { _ in page(top: 0.90, bottom: 0.1) }
        pages.append(page(top: 0.99, bottom: 0.1))
        let area = try XCTUnwrap(PDFFigureCaptionLocator.textArea(pages: pages))
        XCTAssertEqual(area.top, 0.90, accuracy: 1e-9)
    }

    func testUnusableRectanglesAreIgnored() throws {
        var bad = page(top: 0.9, bottom: 0.1)
        bad.append(PDFNormalizedRect(x: 0.1, y: .nan, width: 0.5, height: 0.02))
        bad.append(PDFNormalizedRect(x: 0.1, y: 3, width: 0.5, height: 0.02))
        let area = try XCTUnwrap(PDFFigureCaptionLocator.textArea(pages: [bad, bad, bad]))
        XCTAssertEqual(area.top, 0.9, accuracy: 1e-9)
    }
}
