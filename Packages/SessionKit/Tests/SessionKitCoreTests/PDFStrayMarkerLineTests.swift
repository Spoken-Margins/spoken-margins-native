import XCTest
@testable import SessionKit

final class PDFStrayMarkerLineTests: XCTestCase {
    private typealias Line = PDFStrayMarkerLine.Line

    /// The C1 paper's line, as PDFKit measures it: 9.7 pt type, ending at x = 228.
    private let prose = Line(
        text: "and for simplicity, we assume Gtx = Grx = 1.",
        bounds: CGRect(x: 49, y: 487, width: 179, height: 10), pointSize: 9.7
    )

    /// A stray line: by default the paper's "1", 6.8 pt, starting where the line ends, five points up.
    private func stray(_ text: String = "1", x: CGFloat = 228, y: CGFloat = 492, size: Double = 6.8) -> Line {
        Line(text: text, bounds: CGRect(x: x, y: y, width: 3.3 * CGFloat(text.count), height: 6), pointSize: size)
    }

    func testARaisedNumberAtTheEndOfAProseLineIsItsMarker() {
        XCTAssertTrue(PDFStrayMarkerLine.isMarker(stray(), atEndOf: prose))
        for text in ["12", "1,2", "3–5", "12,14", "101"] {
            XCTAssertTrue(PDFStrayMarkerLine.isMarker(stray(text), atEndOf: prose), text)
        }
        // A paragraph's short last line.
        let short = Line(text: "in the model.", bounds: CGRect(x: 49, y: 487, width: 60, height: 10), pointSize: 9.7)
        XCTAssertTrue(PDFStrayMarkerLine.isMarker(stray(x: 109), atEndOf: short))
        // After a word, a closing bracket or a quote.
        for ending in ["as the earlier work found", "as the earlier work found (see above)", "they called it “simple”"] {
            let line = Line(text: ending, bounds: prose.bounds, pointSize: 9.7)
            XCTAssertTrue(PDFStrayMarkerLine.isMarker(stray(), atEndOf: line), ending)
        }
    }

    func testLookalikeLinesStayLinesOfTheirOwn() {
        let rows: [(String, Line)] = [
            ("set level: a small number on the baseline", stray(y: 488.4)),
            ("lowered: a subscript", stray(y: 484)),
            ("above the line altogether", stray(y: 498)),
            ("the body's size", stray(size: 9.7)),
            ("a little smaller only", stray(size: 8.5)),
            ("a gap after the line: a page or equation number at the right edge", stray(x: 290)),
            ("starting inside the line", stray(x: 200)),
            ("a letter", stray("a")),
            ("a symbol", stray("*")),
            ("a year", stray("2024")),
            ("a decimal", stray("1.5")),
            ("empty", stray("")),
            ("a size PDFKit couldn't give", stray(size: 0)),
        ]
        for (name, candidate) in rows {
            XCTAssertFalse(PDFStrayMarkerLine.isMarker(candidate, atEndOf: prose), name)
        }
    }

    func testOnlyALineOfProseTakesTheNumber() {
        let rows = [
            "16, 17 R. A. Cameron,",            // a byline: its numbers are affiliations
            "1,2, Zhen Yue",
            "C′",                                // pieces of an equation
            "where 0 <ζ ⩽ 1−",
            "|P(x)∇g|pγdx",
            "and so there are 10",               // an exponent after a digit
            "with a spacing of about 5 cm",      // a unit's exponent
            "we then take the largest of these as max", // an operator name's index
            "",
        ]
        for text in rows {
            let line = Line(text: text, bounds: prose.bounds, pointSize: 9.7)
            XCTAssertFalse(PDFStrayMarkerLine.isMarker(stray(), atEndOf: line), text)
        }
        let unsized = Line(text: prose.text, bounds: prose.bounds, pointSize: 0)
        XCTAssertFalse(PDFStrayMarkerLine.isMarker(stray(), atEndOf: unsized))
    }
}
