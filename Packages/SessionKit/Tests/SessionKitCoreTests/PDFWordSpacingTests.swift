import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #2370: a PDF whose fonts carry no space glyph (TeX Gyre Pagella) reads glued through
/// PDFKit. The spacer puts the spaces back with the bundled Kitten word list.
final class PDFWordSpacingTests: XCTestCase {
    /// The word list the app splits with; the test skips, naming it, when the package is checked out alone.
    private func kittenSpacer(context: [String] = []) throws -> PDFWordSpacer {
        let list = try SortedWordList(contentsOf: TestInputs.url(.voiceAssets, "lexicon.tsv"))
        return PDFWordSpacer(isWord: list.contains, context: context)
    }

    func testAGluedLineFromThePaperComesBackSpaced() throws {
        let spacer = try kittenSpacer()
        XCTAssertEqual(
            spacer.respaced("standardtoolfordescribingwhichoccupationsAIislikelytoaffect(Brynjolfsson,Chandar andChen,2025;Webb,2020)"),
            "standard tool for describing which occupations AI is likely to affect (Brynjolfsson, Chandar and Chen, 2025; Webb, 2020)"
        )
        XCTAssertEqual(spacer.respaced("2 Amodelofbottleneck pressure"), "2 A model of bottleneck pressure")
        XCTAssertEqual(spacer.respaced("3.2 Empiricalcounterparts"), "3.2 Empirical counterparts")
        XCTAssertEqual(spacer.respaced("3.3 Comparingthetwo exposuremeasures"), "3.3 Comparing the two exposure measures")
        XCTAssertEqual(
            spacer.respaced("TechnologyBottlenecks:MeasuringWhereAICouldRaisetheValueofWork"),
            "Technology Bottlenecks: Measuring Where AI Could Raise the Value of Work"
        )
        XCTAssertEqual(spacer.respaced("AIuse(Tomlinsonetal.,2025)."), "AI use (Tomlinson et al., 2025).")
        XCTAssertEqual(spacer.respaced("Career/TechnicalEducationTeachers"), "Career/Technical Education Teachers")
        XCTAssertEqual(spacer.respaced("Work.”InProceedingsofthe"), "Work.” In Proceedings of the")
    }

    func testNeighbouringInputsStayAsTheyAre() throws {
        let spacer = try kittenSpacer()
        let unchanged = [
            "The NASA and UNESCO reports",                                   // acronyms
            "See https://example.com/some/longpathwithnospaces today",       // a URL
            "doi:10.1234/abcd.efgh and 10.48550/arXiv.2303.10130",           // DOIs
            "using GPT-4 and O*NET ratings from CO2 data, 1,000 of them",    // identifiers and numbers
            "Brynjolfsson and Acemoglu wrote with Daron, Tonetti and Goldfarb", // names not in the list
            "Measures of AI exposure, which assess the tasks AI can perform, have become the", // already spaced
            "",                                                              // empty
            "He said \"Hello there\" and “Quoted” it, n=12 at a/b",          // quotes and notation
            "In 2026a and 20th, f(x) at 10ms on an iPhone, McDonald, LaTeX and PhD", // notation and case
            String(repeating: "Measures of AI exposure have become the standard tool. ", count: 200), // very long
        ]
        for line in unchanged {
            XCTAssertEqual(spacer.respaced(line), line, line)
        }
        // Ligatures are looked up unfolded and kept as printed.
        XCTAssertEqual(spacer.respaced("ﬁnancialﬂowsandeﬃciencygains"), "ﬁnancial ﬂows and eﬃciency gains")
        XCTAssertEqual(spacer.respaced("eﬃciency"), "eﬃciency")
    }

    func testAWordBrokenAcrossLinesIsSplitWithItsFirstHalf() throws {
        let spacer = try kittenSpacer()
        let line = "erthelessaccount for a small share"
        XCTAssertEqual(PDFWordSpacer.applying(spacer.spaceInsertions(in: line, carried: "Nev"), to: line),
                       "ertheless account for a small share")
    }

    func testOnlyADocumentThatLostItsSpacesIsGlued() throws {
        let spacer = try kittenSpacer()
        let spaced = Array(repeating: "Measures of AI exposure, which assess the tasks AI can perform, have become the", count: 50)
            + ["Pneumonoultramicroscopicsilicovolcanoconiosis is a long word.", "ACGTTGCAACGTTGCAACGT sequence"]
        XCTAssertFalse(spacer.isGlued(spaced))
        let glued = spaced + Array(repeating: "standardtoolfordescribingwhichoccupationsAIislikelytoaffect", count: 3)
        XCTAssertTrue(spacer.isGlued(glued))
        XCTAssertFalse(spacer.isGlued([]))
    }

    func testWordsThePaperPrintsAloneWinTies() throws {
        // "pressureisonascale": without context "ison" (a listed word) can win; a paper
        // that prints "is" and "on" alone reads it "is on".
        let context = Array(repeating: "the pressure is on a scale and it is on the list", count: 20)
        XCTAssertEqual(try kittenSpacer(context: context).respaced("pressureisonascale"), "pressure is on a scale")
        // A name the list lacks, printed alone, splits off a word glued to it.
        let names = Array(repeating: "as Autor and Thompson show", count: 5)
        XCTAssertEqual(try kittenSpacer(context: names).respaced("Autorand Thompson"), "Autor and Thompson")
    }

    func testSuperscriptRangesMoveWithTheText() {
        let spacer = PDFWordSpacer(isWord: ["speeding", "them", "up"].contains)
        let line = "speedingthemup.1Averaged"
        let insertions = spacer.spaceInsertions(in: line, protected: [15..<16])
        let spaced = PDFWordSpacer.applying(insertions, to: line)
        XCTAssertEqual(spaced, "speeding them up.1 Averaged")
        let marker = PDFWordSpacer.shifted(15..<16, by: insertions)
        XCTAssertEqual(String(Array(spaced)[marker]), "1")
    }

    func testAnyWordListWorks() {
        // Runs without the bundled lexicon, so the splitter is checked on every checkout.
        let words: Set<String> = ["standard", "tool", "for", "describing", "which", "occupations", "likely", "to", "affect"]
        let spacer = PDFWordSpacer(isWord: words.contains)
        XCTAssertEqual(spacer.respaced("standardtoolfordescribingwhichoccupations"), "standard tool for describing which occupations")
        XCTAssertEqual(spacer.respaced("Brynjolfsson"), "Brynjolfsson")
    }
}
