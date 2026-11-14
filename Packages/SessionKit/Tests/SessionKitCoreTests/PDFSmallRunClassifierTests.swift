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
        math: Bool = false, raisedCite: Bool = true, _ expected: Kind
    ) -> Row {
        Row(
            name: name,
            run: .init(text: text, before: before, after: after, baselineShift: shift, lineLooksLikeMath: math, raisedNumbersCite: raisedCite),
            expected: expected
        )
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
            row("index raised a little after a lone descender letter", before: "f", "c", after: " grows", shift: 0.1, .mathIndex),
            row("index before an operator", before: "Cost", "p", after: " = 4", .mathIndex),
            row("any small letter run in a math line", before: "loss", "t", after: " + λ", math: true, .mathIndex),
            row("a digit index in a math line", before: "x", "2", after: " + y2", math: true, .mathIndex),
            row("subscript th after a letter (V_th)", before: "threshold V", "th", .mathIndex),
            row("multi-letter subscript after a word", before: "ReLU", "max", .mathIndex),
            row("index after an operator name", before: "argmax", "a", after: " Q(s, a)", .mathIndex),
            row("max_i", before: "the largest max", "i", after: " of", .mathIndex),
            row("lim_n", before: "lim", "n", after: " an", .mathIndex),
            row("log base 2", before: "log", "2", after: " n", .mathIndex),
            row("Reynolds number index", before: "the critical Re", "c", after: " is", .mathIndex),
            row("unit squared", before: "an area of 5 cm", "2", after: " per", .mathIndex),
            row("unit squared, glued", before: "an area of 5cm", "2", .mathIndex),
            row("wavenumber", before: "a band at 1650 cm", "-1", after: " is", .mathIndex),
            row("exponent after a bracket around math", before: "(a+b)", "2", after: " is", .mathIndex),
            row("index after a bracket around math", before: "grows as (1+r)", "n", .mathIndex),
            row("exponent after a norm", before: "the penalty ‖w‖", "2", after: " keeps", .mathIndex),
            row("exponent after an absolute value", before: "|x|", "2", .mathIndex),
            row("compound unit", before: "a speed of 5 m s", "-1", after: " and", .mathIndex),
            row("compound unit after a capital unit", before: "a flux of 1000 W m", "-2", .mathIndex),
            row("CO2 set level", before: "CO", "2", after: " levels", .mathIndex),
            row("H2O set level", before: "H", "2", after: "O", .mathIndex),
            row("CH3OH set level", before: "CH", "3", after: "OH", .mathIndex),
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
            row("star after a byline initial", before: "Author A", "*", .footnoteMarker),
            row("star after a math letter is still a marker (known gap)", before: "the optimum x", "*", .footnoteMarker),
            row("digits after a byline initial", before: "Smith J", "1,2", after: ", Doe K", .footnoteMarker),
            row("letters after a byline initial", before: "Smith J", "a,b", after: ", Doe K", .footnoteMarker),
            row("digits after a one-letter name", before: "Hepatitis B", "12", after: " is", .footnoteMarker),
            row("digit after the word I", before: "as I", "4", after: " argued", .footnoteMarker),
            row("roman numeral footnote", before: "the studies", "ii", after: " were", .footnoteMarker),
            row("marker after a bracket around prose", before: "(Smith, 2020)", "1", after: " and", .footnoteMarker),
            row("marker after a unit word with no number", before: "measured in cm", "2", .footnoteMarker),
            row("marker after a decade", before: "in the 1990s", "1", after: " and", .footnoteMarker),
            row("marker after an age", before: "in her 30s", "2", .footnoteMarker),
            row("marker after a sample size", before: "(n = 24)", "1", .footnoteMarker),
            row("marker after a slash in brackets", before: "(and/or)", "1", .footnoteMarker),
            row("marker after a bracket opened on the line before", before: "p = 0.03)", "1", .footnoteMarker),
            row("marker after a trademark", before: "Excel™", "1", .footnoteMarker),
            row("letters after a hyphenated byline name", before: "Smith-Jones J", "a", after: ", Doe K", .footnoteMarker),
            row("roman numeral list", before: "the studies", "ii,iii", .footnoteMarker),
            row("marker after an acronym that isn't a formula", before: "NASA", "3", after: " and", .footnoteMarker),
            row("raised marker", before: "cost", "4", shift: 0.4, .footnoteMarker),
            row("unknown position", before: "cost", "4", shift: nil, .footnoteMarker),
        ])
    }

    /// The index shapes #4194 left silenced on the C1 corpus (#4254), each with the marker that looks like it.
    func testALetterWithADigitStraightAfterItIsAnIndex() {
        check([
            row("Nav1.2", before: "the voltage-gated sodium channel Na", "v", after: "1.2, is strongly", .mathIndex),
            row("Kv7.2", before: "loss of K", "v", after: "7.2 current", .mathIndex),
            row("Ci1i2", before: "coefficients Ci1", "i", after: "2...iN", .mathIndex),
            row("two letters", before: "the term GL", "nr", after: "2", .mathIndex),
            // The neighbours: a letter marker ends at a space, a comma, a bracket or the line.
            row("a number after a space", before: "Jane Doe", "a", after: " 2 John Roe", .footnoteMarker),
            row("a comma, then a number", before: "Jane Doe", "a", after: ",1 John Roe", .footnoteMarker),
            row("a letter list before a digit", before: "Jane Doe", "a,b", after: "1", .footnoteMarker),
            row("at the line's end", before: "the WHO", "a", .footnoteMarker),
            row("before a year in brackets", before: "the WHO", "a", after: " (2010)", .footnoteMarker),
            row("a number before a digit", before: "the cohort", "3", after: "1 more", .footnoteMarker),
        ])
    }

    func testIndexShapesTheFirstRulesMissed() {
        check([
            // No citation is numbered 0.
            row("L0", before: "where L", "0", after: " and L1 are", .mathIndex),
            row("C0,1", before: "for all X ∈C", "0,1", after: "(RN)", .mathIndex),
            row("zero after a word", before: "the rate", "0", after: " is", .mathIndex),
            row("a list that only holds a zero later", before: "the rate", "1,0", .footnoteMarker),
            row("zero after a full stop", before: "in 1999.", "0", .footnoteMarker),
            // Applied like a function.
            row("GLn(k)", before: "generators of GL", "n", after: "(k)", .mathIndex),
            row("Canonp(M)", before: "A:= Canon", "p", after: "(M). (2)", .mathIndex),
            row("QTs0,a(n)", before: "QT", "s0,a", after: "(n)(s0,a)", .mathIndex),
            row("footnote letter before a spaced bracket", before: "Jane Doe", "a", after: " (Oslo)", .footnoteMarker),
            row("number before a bracket", before: "the cohort", "3", after: "(see Table 2)", .footnoteMarker),
            // An index list carried on from the run before.
            row("Tsd,ad(t)", before: "Tsd", ",a", after: "d(t)", .mathIndex),
            row("Tn1,n2", before: "Tn1", ",n", after: "2,n3,n4(s)", .mathIndex),
            row("h′,i′", before: "h′", ",i", after: "′(n) =", .mathIndex),
            row("letter after an affiliation number", before: "Lingqun Mao1", ",a", after: ", Hongsheng Lu2", .footnoteMarker),
            row("letter after an affiliation number, before and", before: "Lingqun Mao1", ",a", after: " and Peng Liu", .footnoteMarker),
            row("letter after an affiliation number, at the line's end", before: "Lingqun Mao1", ",a", .footnoteMarker),
            // A unit under a slash, or alone in brackets.
            row("g/cm3", before: "its density is 7.15 g/cm", "3", after: " (World Health", .mathIndex),
            row("W/m2", before: "a flux in W/m", "2", .mathIndex),
            row("(cm2) heading a column", before: "Leaf area (cm", "2", after: ") 74 72", .mathIndex),
            row("a word under a slash", before: "and/or", "1", .footnoteMarker),
            row("a unit word opening a bracket of prose", before: "(m", "2", after: " is the mass)", .footnoteMarker),
            row("a letter after a unit under a slash", before: "in g/cm", "a", .footnoteMarker),
            // After a brace or an angle bracket.
            row("{xt}n", before: "variables {xt}", "n", .mathIndex),
            row("{Mv}5", before: "anomaly masks {Mv}", "5", .mathIndex),
            row("⟨C⟩r", before: "Var[⟨C⟩", "r", after: "]t", .mathIndex),
            row("⟨·⟩t", before: "Where ⟨…⟩", "t", after: " denotes", .mathIndex),
        ])
    }

    /// A digit after a lone letter is an index where the document doesn't cite with raised numbers (#4254).
    func testDigitsAfterALoneLetterFollowTheDocument() {
        let shapes: [(name: String, before: String, text: String, after: String)] = [
            ("X3", "constants X1, X2, and X", "3", "."),
            ("R2", "the out-of-sample R", "2", " from a regression"),
            ("K1(R)", "by determining K", "1", "(R) we mean"),
            ("F2[G]", "the group rings F", "2", "[G] for all"),
            ("lower-case s1", "the next state s", "1", ", and"),
            ("index list", "the space C", "1,1", " of regular domains"),
            ("W1,p", "a weak solution u∈g +W", "1,p", ""),
            ("En,2", "the second term E", "n,2", " in (5)"),
            ("kb2", "dt= k", "b2", "[Ap][P]"),
            ("name-like lower-case word before", "hepatitis B", "12", " is"),
            ("after a bracket", "(X", "0", ")"),
            ("after a coefficient", "costs approximately 4M", "2", "dh FLOPs"),
            ("after a coefficient and an indexed letter", "requires ≈2a1a", "2", "a3 FLOPs"),
        ]
        check(shapes.map { row($0.name + ", brackets cite", before: $0.before, $0.text, after: $0.after, raisedCite: false, .mathIndex) })
        // Where raised numbers cite, every one of these may be a citation. The zero is the exception.
        check(shapes.filter { !$0.text.hasPrefix("0") }.map {
            row($0.name + ", raised numbers cite", before: $0.before, $0.text, after: $0.after, raisedCite: true, .footnoteMarker)
        })
        // Bylines and names stay silent whatever the document does.
        check([
            row("byline initial", before: "Smith J", "1,2", after: ", Doe K", raisedCite: false, .footnoteMarker),
            row("byline initial before and", before: "Smith J", "1", after: " and Doe K", raisedCite: false, .footnoteMarker),
            row("byline initial after a comma", before: "Smith, J", "1", raisedCite: false, .footnoteMarker),
            row("byline initial after a hyphenated name", before: "Smith-Jones J", "3", raisedCite: false, .footnoteMarker),
            row("one-letter name after a capitalised word", before: "Hepatitis B", "12", after: " is", raisedCite: false, .footnoteMarker),
            row("the word I", before: "as I", "4", after: " argued", raisedCite: false, .footnoteMarker),
            row("a letter that ends a number in a name", before: "the model roberta-8k", "4", after: " for Polish", raisedCite: false, .footnoteMarker),
            row("a letter that ends a number in a glued name", before: "SyjGCaMP8m", "18", raisedCite: false, .footnoteMarker),
            row("digit after a word", before: "aptitude", "1", after: " and", raisedCite: false, .footnoteMarker),
            row("digit after a full stop", before: "in 1999.", "2", raisedCite: false, .footnoteMarker),
            row("affiliation digits", before: "John Roe", "1,2", raisedCite: false, .footnoteMarker),
            row("acronym", before: "NASA", "3", after: " and", raisedCite: false, .footnoteMarker),
            row("letter after a table number", before: "12.5", "a", raisedCite: false, .footnoteMarker),
            row("letter after an acronym", before: "WHO", "a", raisedCite: false, .footnoteMarker),
            row("letter footnotes", before: "Jane Doe", "a,b", after: ", John Roe", raisedCite: false, .footnoteMarker),
        ])
    }

    func testOrdinalsExponentsAndSubscriptsAreLeftAlone() {
        check([
            row("20th", before: "the 20", "th", after: " century", .text),
            row("1st", before: "the 1", "st", .text),
            row("10⁵", before: "about 10", "5", after: " cells", shift: 0.4, .mathIndex),
            row("10⁻⁵ with a hyphen", before: "below 10", "-5", shift: 0.4, .mathIndex),
            row("10⁻⁵ with an en dash", before: "below 10", "–5", shift: 0.4, .mathIndex),
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
            row("twelve digits", before: "word", "123456789012", .footnoteMarker),
            row("nothing before", before: "", "1", after: " See the appendix", .text),
            row("space before", before: "word ", "1", .text),
            row("trailing space on the run", before: "aptitude", "1 ", after: "and", .footnoteMarker),
            row("leading space on the run, as the extractor reads it", before: "word", " 1", .text),
            row("Unicode superscript digit, which the extractor doesn't take", before: "aptitude", "¹", .text),
            row("Unicode superscript letter", before: "x", "ⁿ", .text),
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
