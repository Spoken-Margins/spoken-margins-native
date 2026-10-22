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
        XCTAssertEqual(spacer.respaced("postinglinesarematchedtoO*NET tasks"), "posting lines are matched to O*NET tasks")
    }

    /// The runs a first pass over the paper left glued (#2370).
    func testPossessivesMathAndCapitalisedWordsSplit() throws {
        let spacer = try kittenSpacer()
        XCTAssertEqual(spacer.respaced("ratherthanjustthoseonthepostingoccupation’sO*NET"),
                       "rather than just those on the posting occupation’s O*NET")
        XCTAssertEqual(spacer.respaced("soeachoccupation’sAI-infeasiblework"), "so each occupation’s AI-infeasible work")
        XCTAssertEqual(spacer.respaced("therecipient’sGenome"), "the recipient’s Genome")
        XCTAssertEqual(spacer.respaced("whenever 𝜎 < 1 ≤𝜌butcanfailwhen𝜌 < 1"), "whenever 𝜎 < 1 ≤𝜌 but can fail when 𝜌 < 1")
        XCTAssertEqual(spacer.respaced("Wang.2026.“GenerativeAIandtheReorganization"), "Wang. 2026. “Generative AI and the Reorganization")
        // Unchanged: a possessive already spaced, math in a spaced line, an abbreviation, a version.
        for line in ["the occupation’s AI work", "for each 𝑡 in 𝑜", "e.g.2 and v1.2"] {
            XCTAssertEqual(spacer.respaced(line), line, line)
        }
    }

    /// A phrase the paper glues the same way every time ("Full notes attheendof the table."
    /// eight times) is not taken for a name the paper prints alone.
    func testAPhraseGluedTheSameWayEachTimeSplits() throws {
        let context = Array(repeating: "Fullnotes attheendof the table.", count: 8)
        XCTAssertEqual(try kittenSpacer(context: context).respaced("Fullnotes attheendof the table."), "Full notes at the end of the table.")
    }

    /// Names, units and terms the corpus's glued papers showed being split (#2370).
    func testNamesUnitsAndTermsInAGluedPaperStayWhole() throws {
        let context = Array(repeating: "replicates of BspizHyb, BvalHyb and GeoHyb were run", count: 3)
            + ["Wedetectregionsuniquetotherecipient", "for the re-", "cipient strain", "the recipient", "the recipient"]
        let spacer = try kittenSpacer(context: context)
        XCTAssertEqual(spacer.respaced("each BspizHyb, BvalHyb, GeoHyb and"), "each BspizHyb, BvalHyb, GeoHyb and")
        XCTAssertEqual(spacer.respaced("we use Bacillus vallismortis and B. vallismortis"), "we use Bacillus vallismortis and B. vallismortis")
        XCTAssertEqual(spacer.respaced("higherconfinement(0.4–0.7GPa),thespecimens"), "higher confinement (0.4–0.7GPa), the specimens")
        XCTAssertEqual(spacer.respaced("respecttotherecipient’sgenome."), "respect to the recipient’s genome.")
        XCTAssertEqual(try kittenSpacer(context: Array(repeating: "B. subtilis", count: 4)).respaced("Here,Bacillussubtilisis Bacillus subtilis"),
                       "Here, Bacillus subtilis is Bacillus subtilis")
        XCTAssertEqual(spacer.respaced("theMWDsinthesample"), "the MWDs in the sample")
        XCTAssertEqual(spacer.respaced("meetsBGI’sinternalhigh-confidence threshold"), "meets BGI’s internal high-confidence threshold")
        XCTAssertEqual(spacer.respaced("nonmetal, acetal, Sheetal and H2SO4 in 2019Baumol, Kwaetal.,2025"),
                       "nonmetal, acetal, Sheetal and H2SO4 in 2019 Baumol, Kwa et al., 2025")
        // Product and company names the paper prints whole stay whole, even when each half is a word.
        let products = try kittenSpacer(context: Array(repeating: "TensorFlow, GitHub, OpenAI, DeepMind and LinkedIn", count: 3))
        XCTAssertEqual(products.respaced("we used TensorFlow, DeepMind and LinkedIn"), "we used TensorFlow, DeepMind and LinkedIn")
        XCTAssertEqual(products.respaced("datafromOpenAIandGitHub"), "data from OpenAI and GitHub")
        XCTAssertEqual(products.respaced("Brynjolfsson,Chandar andChen,2025"), "Brynjolfsson, Chandar and Chen, 2025")
        let headings = try kittenSpacer(context: Array(repeating: "ComparativeAdvantage", count: 4))
        XCTAssertEqual(headings.respaced("theComparativeAdvantageof"), "the Comparative Advantage of")
        // E-mail addresses are not glued prose.
        let addresses = Array(repeating: "Contact: firstname.lastname@burningglassinstitute.org", count: 5)
        XCTAssertFalse(spacer.isGlued(addresses))
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
        let broken = "compareseachmajoroccupationgroup’sshareofadver-"
        XCTAssertEqual(PDFWordSpacer.applying(spacer.spaceInsertions(in: broken, continued: "tised"), to: broken),
                       "compares each major occupation group’s share of adver-")
    }

    func testOnlyADocumentThatLostItsSpacesIsGlued() throws {
        let spacer = try kittenSpacer()
        let spaced = Array(repeating: "Measures of AI exposure, which assess the tasks AI can perform, have become the", count: 50)
            + ["Pneumonoultramicroscopicsilicovolcanoconiosis is a long word.", "ACGTTGCAACGTTGCAACGT sequence"]
        XCTAssertFalse(spacer.isGlued(spaced))
        let glued = spaced + Array(repeating: "standardtoolfordescribingwhichoccupationsAIislikelytoaffect", count: 3)
        XCTAssertTrue(spacer.isGlued(glued))
        XCTAssertFalse(spacer.isGlued([]))
        // A methods section's primers and chemicals are long runs too (C1 corpus, PMC10950207
        // and PMC10777729), but no glued prose: no common word in them.
        let methods = Array(repeating: "Human GAPDH ACAACTTTGGTATCGTGGAAGG GCCATCACGCCACAGTTTC", count: 6)
            + Array(repeating: "5´-ATTCTTTTACGGCGGATGTG-3′ (forward) in tetramethylbenzidine substrate", count: 6)
            + Array(repeating: "Hypocholesterolemic and antioxidative effects of naringenin", count: 6)
        XCTAssertFalse(spacer.isGlued(methods))
    }

    func testBiologyTermsKeepTheirCase() throws {
        // Terms the paper prints alone keep their case; an acronym after a word splits ("forAI").
        let context = Array(repeating: "microRNA miRNA circRNAs lncRNA microRNA miRNA", count: 2)
        let spacer = try kittenSpacer(context: context)
        XCTAssertEqual(spacer.respaced("showingthatforanAI-infeasible task"), "showing that for an AI-infeasible task")
        for line in ["a microRNA-375 sponge", "Circular RNAs (circRNAs) act as microRNA (miRNA) sponges", "targeted by miR-375",
                     "receptor OAα1 and circ0051246", "in MALAT1 lncRNA, G-quadruplex structures", "© The Author(s) 2023",
                     "alternative splicing and chromatin orga-"] {
            XCTAssertEqual(spacer.respaced(line), line)
        }
        // A species name the paper prints alone stays whole; glued to a word, it splits off (PMC10756544).
        // PMC11314421 prints "lncRNAs" alone; glued to "can", it splits off whole.
        let terms = Array(repeating: "the lncRNAs and lncRNAs", count: 2)
        XCTAssertEqual(try kittenSpacer(context: terms).respaced("cellular compartments, lncRNAscanfunctionasdecoysfor"),
                       "cellular compartments, lncRNAs can function as decoys for")
        let species = Array(repeating: "in Rhodnius prolixus females", count: 6)
        XCTAssertEqual(try kittenSpacer(context: species).respaced("R. prolixus and R. prolixusreproduction"),
                       "R. prolixus and R. prolixus reproduction")
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
        // No space goes in front of a marker set on a word: "economy¹", not "economy 1".
        let onWord = "theeconomy1Averaged"
        let onWordInsertions = spacer.spaceInsertions(in: onWord, protected: [10..<11])
        XCTAssertFalse(onWordInsertions.contains(10))
    }

    func testAnyWordListWorks() {
        // Runs without the bundled lexicon, so the splitter is checked on every checkout.
        let words: Set<String> = ["standard", "tool", "for", "describing", "which", "occupations", "likely", "to", "affect"]
        let spacer = PDFWordSpacer(isWord: words.contains)
        XCTAssertEqual(spacer.respaced("standardtoolfordescribingwhichoccupations"), "standard tool for describing which occupations")
        XCTAssertEqual(spacer.respaced("Brynjolfsson"), "Brynjolfsson")
    }
}
