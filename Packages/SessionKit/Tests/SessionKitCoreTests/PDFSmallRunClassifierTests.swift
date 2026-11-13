import XCTest
@testable import SessionKit

/// Small type beside a letter in a PDF: a footnote marker the listener shouldn't hear, or a math index they should
/// (#4074). The C1 corpus silenced 2,758 letter "markers" in 42 of 64 papers, most of them subscripts.
final class PDFSmallRunClassifierTests: XCTestCase {
    private typealias Kind = PDFSmallRunClassifier.Kind

    private struct Row {
        let name: String
        let run: PDFSmallRunClassifier.Run
        let expected: Kind
    }

    /// `shift` is the run's bottom less the bottom of the letter before it, in main-size units: 0 is level, below
    /// -0.15 is lowered.
    private func row(
        _ name: String, before: String, _ text: String, after: String = "", shift: Double? = 0,
        math: Bool = false, _ expected: Kind
    ) -> Row {
        Row(name: name, run: .init(text: text, before: before, after: after, baselineShift: shift, lineLooksLikeMath: math), expected: expected)
    }

    private func check(_ rows: [Row], file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            XCTAssertEqual(PDFSmallRunClassifier.classify(row.run), row.expected, row.name, file: file, line: line)
        }
    }

    /// The subscripts the C1 corpus silenced. Each is set level with, or barely below, the letter before it, which
    /// is how they passed the old baseline guard.
    func testMathIndicesAreSpokenEvenWhenSetLevel() {
        check([
            row("x_n", before: "where x", "n", after: " is the input", .mathIndex),
            row("h_t", before: "the hidden state h", "t", after: ".", .mathIndex),
            row("h_t inside brackets", before: "softmax(h", "t", after: ")", .mathIndex),
            row("F_i = v_i", before: "F", "i", after: " = vi", .mathIndex),
            row("v_i at the end of a formula", before: "Fi = v", "i", .mathIndex),
            row("A_con", before: "the area A", "con", after: " of the contact", .mathIndex),
            row("h,i double index", before: "weight w", "h,i", after: " between", .mathIndex),
            row("log under a product sign", before: "∏", "log", after: " p(x)", shift: -0.6, .mathIndex),
            row("log under a product sign, set level", before: "∏", "log", after: " p(x)", .mathIndex),
            row("index after a math-font letter", before: "where 𝑥", "n", after: " is", .mathIndex),
            row("index after a Greek letter", before: "the rate β", "s", after: " is", .mathIndex),
            row("index after a descender letter, raised a little", before: "f", "c", after: " grows", shift: 0.1, .mathIndex),
            row("index before an operator", before: "Cost", "p", after: " = 4", .mathIndex),
            row("any small letter run in a math line", before: "loss", "t", after: " + λ", math: true, .mathIndex),
            row("a digit index in a math line", before: "x", "2", after: " + y2", math: true, .mathIndex),
            row("subscript th after a letter (V_th)", before: "threshold V", "th", .mathIndex),
            row("multi-letter subscript after a word", before: "ReLU", "max", .mathIndex),
        ])
    }

    /// What the old rule got right must stay right.
    func testFootnoteMarkersAreStillSilenced() {
        check([
            row("digit marker after a word", before: "aptitude", "1", after: " and", .footnoteMarker),
            row("digit marker after a comma", before: "aptitude,", "1", after: " and", .footnoteMarker),
            row("marker list", before: "effects", "12,14", after: ".", .footnoteMarker),
            row("marker range", before: "studies", "3–5", .footnoteMarker),
            row("letter footnote a", before: "the sample", "a", after: " was", .footnoteMarker),
            row("letter footnotes a,b", before: "Jane Doe", "a,b", after: ", John Roe", .footnoteMarker),
            row("letter footnote after a full stop", before: "in 1999.", "b", .footnoteMarker),
            row("affiliation digits", before: "John Roe", "1,2", .footnoteMarker),
            row("dagger", before: "Roe", "†", .footnoteMarker),
            row("star after a single letter is a symbol marker", before: "Author A", "*", .footnoteMarker),
            row("raised marker", before: "cost", "4", shift: 0.4, .footnoteMarker),
            row("unknown position", before: "cost", "4", shift: nil, .footnoteMarker),
        ])
    }

    func testOrdinalsExponentsAndSubscriptsAreLeftAlone() {
        check([
            row("20th", before: "the 20", "th", after: " century", .text),
            row("1st", before: "the 1", "st", .text),
            row("10⁵", before: "about 10", "5", after: " cells", shift: 0.4, .mathIndex),
            row("CO2 lowered", before: "CO", "2", after: " levels", shift: -0.3, .mathIndex),
            row("H2O lowered", before: "H", "2", after: "O", shift: -0.3, .mathIndex),
        ])
    }

    func testNeighbouringInputs() {
        check([
            row("empty", before: "word", "", .text),
            row("whitespace only", before: "word", "  ", .text),
            row("very long", before: "word", String(repeating: "a", count: 40), .text),
            row("thirteen digits", before: "word", "1234567890123", .text),
            row("nothing before", before: "", "1", after: " See the appendix", .text),
            row("space before", before: "word ", "1", .text),
            row("trailing space on the run", before: "aptitude", "1 ", after: "and", .footnoteMarker),
            row("Unicode superscript digit", before: "aptitude", "¹", .footnoteMarker),
            row("Unicode superscript letter after a single letter", before: "x", "ⁿ", .mathIndex),
            row("decomposed accent before", before: "cafe\u{301}", "1", .footnoteMarker),
            row("upper case run (transpose)", before: "W", "T", .text),
            row("bracketed run", before: "word", "[1]", .text),
            row("upper case letter marker", before: "word", "A", .text),
            row("index after a single capital", before: "the set S", "k", .mathIndex),
            row("lowered letter after a word", before: "rate", "a", shift: -0.3, .mathIndex),
            row("exactly at the lowered line", before: "rate", "a", shift: -0.15, .footnoteMarker),
        ])
    }

    func testOnlyMarkersAreSilenced() {
        XCTAssertTrue(Kind.footnoteMarker.isSilenced)
        XCTAssertFalse(Kind.mathIndex.isSilenced)
        XCTAssertFalse(Kind.text.isSilenced)
    }
}
