import XCTest
@testable import SessionKit

/// #1144 (Test Desk T4 on next 6a22bb8): the CASP working paper's section heading
/// "Automating AI R&D could trigger an intelligence explosion" is printed over two
/// lines, and each line became a chapter. The geometry in the first row is the real
/// paper's (page 4, PDFKit on macOS); the other rows are its neighbours.
final class PDFWrappedHeadingTests: XCTestCase {
    private typealias Line = PDFWrappedHeading.Line

    /// A 14.3 pt heading line in the right column, `below` lines under the first.
    private func line(_ text: String, below: Int = 0, page: Int = 3, size: Double = 14.3, bold: Bool = false,
                      minX: Double = 302.6, width: Double? = nil, pitch: Double = 18.0) -> Line {
        let top = 422.7 - Double(below) * pitch
        return Line(text: text, pageIndex: page, pointSize: size, isBold: bold,
                    minX: minX, maxX: minX + (width ?? Double(text.count) * 6.5), minY: top - 14.7, maxY: top)
    }

    private func joins(_ lines: [Line], file: StaticString = #filePath, lineNumber: UInt = #line) -> String? {
        guard lines.count >= 2 else { return nil }
        for index in 1..<lines.count where !PDFWrappedHeading.continues(lines[index - 1], with: lines[index]) {
            return nil
        }
        return PDFWrappedHeading.joined(lines.map(\.text))
    }

    func testTheRealPapersWrappedHeadingIsOneHeading() {
        let first = Line(text: "Automating AI R&D could trigger an", pageIndex: 3, pointSize: 14.3, isBold: false,
                         minX: 302.6, maxX: 548.3, minY: 408.0, maxY: 422.7)
        let second = Line(text: "intelligence explosion", pageIndex: 3, pointSize: 14.3, isBold: false,
                          minX: 302.6, maxX: 441.1, minY: 390.0, maxY: 404.8)
        XCTAssertEqual(joins([first, second]), "Automating AI R&D could trigger an intelligence explosion")
    }

    func testNeighbouringInputsThatAreOneWrappedHeading() {
        let rows: [(String, [Line], String)] = [
            ("three lines", [line("Automating AI R&D could"), line("trigger an intelligence", below: 1), line("explosion", below: 2)],
             "Automating AI R&D could trigger an intelligence explosion"),
            ("Title Case, second line capitalised", [line("Automating AI R&D Could Trigger"), line("An Intelligence Explosion", below: 1)],
             "Automating AI R&D Could Trigger An Intelligence Explosion"),
            ("ALL CAPS", [line("AUTOMATING AI R&D COULD TRIGGER"), line("AN INTELLIGENCE EXPLOSION", below: 1)],
             "AUTOMATING AI R&D COULD TRIGGER AN INTELLIGENCE EXPLOSION"),
            ("bold headings", [line("Automating AI R&D could trigger an", bold: true), line("intelligence explosion", below: 1, bold: true)],
             "Automating AI R&D could trigger an intelligence explosion"),
            ("centred lines (different left edges, same centre)",
             [line("What if automating AI R&D triggers an", minX: 65.9, width: 462.1), line("intelligence explosion?", below: 1, minX: 163.0, width: 270.5)],
             "What if automating AI R&D triggers an intelligence explosion?"),
            ("extra whitespace", [line("Automating AI R&D  could trigger an  "), line("  intelligence explosion", below: 1)],
             "Automating AI R&D could trigger an intelligence explosion"),
            ("decomposed accent kept as printed", [line("Re\u{301}gulation de l'IA et"), line("explosion d'intelligence", below: 1)],
             "Re\u{301}gulation de l'IA et explosion d'intelligence"),
            ("line-end hyphen in a compound", [line("Large-"), line("scale automation of AI R&D", below: 1)],
             "Large-scale automation of AI R&D"),
            ("comma at the break", [line("Risks, benefits,"), line("and policy responses", below: 1)],
             "Risks, benefits, and policy responses"),
            ("colon at the break", [line("Part one:"), line("why AI R&D matters", below: 1)],
             "Part one: why AI R&D matters"),
            ("tight leading", [line("Automating AI R&D could trigger an"), line("intelligence explosion", below: 1, pitch: 14.6)],
             "Automating AI R&D could trigger an intelligence explosion"),
        ]
        for (name, lines, expected) in rows {
            XCTAssertEqual(joins(lines), expected, name)
        }
    }

    func testNeighbouringInputsThatAreSeparateLines() {
        let rows: [(String, Line, Line)] = [
            ("a gap of a blank line or more: two headings",
             line("Societal impacts"), line("Policy implications", below: 1, pitch: 40)),
            ("next starts a numbered section", line("1 Introduction"), line("2 Methods", below: 1)),
            ("next starts a decimal subsection", line("Why automate AI R&D"), line("2.1 Hardware", below: 1)),
            ("next is a standalone section name", line("Acknowledgments"), line("References", below: 1)),
            ("next is Appendix A", line("Supplementary Materials"), line("Appendix A", below: 1)),
            ("first ends a sentence", line("Why now?"), line("What changes in policy", below: 1)),
            ("first ends with a full stop", line("Policy implications."), line("Visibility comes first", below: 1)),
            ("different size", line("Automating AI R&D could trigger an"), line("intelligence explosion", below: 1, size: 12.0)),
            ("different weight", line("Automating AI R&D could trigger an", bold: true), line("intelligence explosion", below: 1)),
            ("next page (heading at a page break)", line("Automating AI R&D could trigger an"), line("intelligence explosion", page: 4)),
            ("next column (higher on the page)", line("Automating AI R&D could trigger an"),
             line("intelligence explosion", below: -20, minX: 47.0)),
            ("same height, side by side", line("Automating AI R&D", minX: 47.0), line("intelligence explosion")),
            ("different column, same pitch", line("Automating AI R&D could trigger an", minX: 47.0, width: 220),
             line("intelligence explosion", below: 1, minX: 302.6, width: 140)),
            ("empty next line", line("Automating AI R&D could trigger an"), line("   ", below: 1)),
            ("very long run", line(String(repeating: "automation ", count: 11)), line(String(repeating: "explosion ", count: 10), below: 1)),
        ]
        for (name, first, second) in rows {
            XCTAssertFalse(PDFWrappedHeading.continues(first, with: second), name)
        }
    }

    func testAtMostThreeLinesJoin() {
        XCTAssertEqual(PDFWrappedHeading.maximumLines, 3)
    }
}
