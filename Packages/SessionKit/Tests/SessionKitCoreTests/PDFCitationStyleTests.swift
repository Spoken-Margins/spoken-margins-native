import XCTest
@testable import SessionKit

/// Whether a PDF cites with raised numbers, counted over the document (#4254).
final class PDFCitationStyleTests: XCTestCase {
    private func run(_ before: String, _ text: String, after: String = "", math: Bool = false) -> PDFSmallRunClassifier.Run {
        .init(text: text, before: before, after: after, baselineShift: 0.4, lineLooksLikeMath: math)
    }

    func testCountsRaisedNumbersAfterProseOnly() {
        let counted: [(String, PDFSmallRunClassifier.Run)] = [
            ("after a word", run("aptitude", "1", after: " and")),
            ("after a comma", run("aptitude,", "2")),
            ("after a full stop", run("to others.", "3", after: " The")),
            ("a list", run("effects", "12,14")),
            ("a range", run("studies", "3–5")),
            ("after a closing bracket", run("(Smith, 2020)", "6")),
            ("after a closing quote", run("and “color.”", "1")),
        ]
        for (name, run) in counted {
            XCTAssertTrue(PDFCitationStyle.isRaisedNumberAfterProse(run), name)
        }
        let notCounted: [(String, PDFSmallRunClassifier.Run)] = [
            ("after a lone letter", run("the state s", "1")),
            ("after a byline initial", run("Smith J", "1,2")),
            ("after a name, where an affiliation number sits", run("Adam Abdullahi", "1,2")),
            ("after a unit under a slash", run("its density is 7.15 g/cm", "3")),
            ("after a unit in brackets", run("Leaf area (cm", "2", after: ") 74 72")),
            ("after capitals", run("the group GL", "2")),
            ("after an acronym", run("NASA", "3")),
            ("an exponent", run("about 10", "5")),
            ("a unit", run("an area of 5 cm", "2")),
            ("a formula", run("CO", "2", after: " levels")),
            ("in display math", run("loss", "2", math: true)),
            ("a letter", run("the sample", "a")),
            ("a dagger", run("Roe", "†")),
            ("an ordinal", run("the 20", "th")),
            ("a zero", run("the rate", "0")),
            ("commas only", run("the rate", ",")),
            ("nothing before", run("", "1")),
            ("a space before", run("word ", "1")),
        ]
        for (name, run) in notCounted {
            XCTAssertFalse(PDFCitationStyle.isRaisedNumberAfterProse(run), name)
        }
    }

    /// A paper already known to cite in brackets is counted the same way: the count can't lean on its own answer.
    func testTheCountIgnoresWhatTheRunSaysAboutTheDocument() {
        var known = run("aptitude", "1")
        known.raisedNumbersCite = false
        XCTAssertTrue(PDFCitationStyle.isRaisedNumberAfterProse(known))
    }

    func testCountsNumbersInSquareBrackets() {
        let rows: [(String, Int)] = [
            ("as shown before [12].", 1),
            ("several studies [3, 5–7] and [9;11] agree [14-16]", 3),
            ("spaces [ 12 ] are not a citation here", 0),
            ("an interval [0,1] is counted, which errs towards brackets", 1),
            ("a label [BL22] or a locator [7, Lemma A.1] is not", 0),
            ("[12] A. Author, a reference list entry, is not", 0),
            ("[12] An entry that cites another [14] counts that one", 1),
            ("round ones (12) are an equation or a list item as often", 0),
            ("a year [2020] has four digits", 0),
            ("", 0),
        ]
        for (line, expected) in rows {
            XCTAssertEqual(PDFCitationStyle.bracketedNumbers(in: line), expected, line)
        }
    }

    func testADocumentCitesWithRaisedNumbersWhenTheyAreManyAndOutnumberBrackets() {
        let rows: [(name: String, raised: Int, bracketed: Int, expected: Bool)] = [
            ("nothing counted", 0, 0, false),
            ("a few footnotes", 5, 0, false),
            ("nine", 9, 0, false),
            ("ten", 10, 0, true),
            ("a paper of raised citations", 130, 2, true),
            ("affiliations in a paper that cites in brackets", 13, 107, false),
            ("as many brackets as raised numbers", 40, 40, false),
            ("one more raised number than brackets", 41, 40, true),
        ]
        for row in rows {
            let style = PDFCitationStyle(raisedAfterProse: row.raised, bracketed: row.bracketed)
            XCTAssertEqual(style.citesWithRaisedNumbers, row.expected, row.name)
        }
    }

    func testCountingALineAddsItsBracketsAndItsRaisedNumbers() {
        var style = PDFCitationStyle()
        style.count(line: "aptitude1 as shown [12] and x2", runs: [run("aptitude", "1", after: " as shown [12] and x2"), run("aptitude1 as shown [12] and x", "2")])
        style.count(line: "no small runs [3]", runs: [])
        XCTAssertEqual(style, PDFCitationStyle(raisedAfterProse: 1, bracketed: 2))
    }
}
