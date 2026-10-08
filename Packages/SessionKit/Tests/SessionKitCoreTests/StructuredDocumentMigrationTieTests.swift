import XCTest
@testable import SessionKit

/// "Every text-anchored Margin lands on exactly the same words in the new text, otherwise the
/// item stays on its old extraction." When the same words appear more than once in the new text
/// the stored context decides, and a tie must leave the item where it is: picking one of two
/// equally good passages would move the listener's Margin onto the wrong sentence while the
/// upgrade reports success.
///
/// The only existing tie case (`testRepeatedWordsAreSettledByContextOrLeftWhereTheyAre`, last
/// block) gives the anchor context "x" / "y" that matches neither candidate, so both score 0 and
/// the `best > 0` guard returns before the tie guard is ever reached.
final class StructuredDocumentMigrationTieTests: XCTestCase {
    private typealias Anchor = StructuredDocumentMigration.TextAnchor

    private func range(of words: String, in text: String, occurrence: Int = 0) -> Range<Int> {
        var searchStart = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = text.range(of: words, range: searchStart..<text.endIndex)
            searchStart = found!.upperBound
        }
        let lower = text.distance(from: text.startIndex, to: found!.lowerBound)
        return lower..<(lower + words.count)
    }

    func testTwoPassagesThatMatchTheStoredContextEquallyAreATieAndTheMarginStays() {
        // Both new copies are preceded by a space and followed by a full stop, which is all the stored context says.
        let old = "A. Same line.\nB. Same line."
        let new = "Top\nA. Same line.\nB. Same line."
        let first = range(of: "Same line", in: old)
        let outcome = StructuredDocumentMigration.place(
            [Anchor(id: "t", start: first.lowerBound, end: first.upperBound, before: " ", after: ".")], from: old, into: new
        )
        XCTAssertEqual(outcome, .stays(unplaced: ["t"]), "two equally good passages must not be settled by taking the first")
    }

    func testTwoPassagesThatMatchTheOldSurroundingsEquallyAreATieAndTheMarginStays() {
        // No stored context, so the 40 characters around the old range are used: "q " before and " b" after.
        // In the new text each copy shares only the single space on each side with them.
        let old = "q Same line. b"
        let new = "gamma Same line. delta\nepsilon Same line. zeta"
        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "t", start: 2, end: 11)], from: old, into: new),
            .stays(unplaced: ["t"])
        )
    }

    func testAMarginOnTheSecondOfTwoIdenticalPassagesStaysOnTheSecondAndOneOnTheFirstOnTheFirst() {
        let old = "A. Same line.\nB. Same line."
        let new = "Top\n" + old
        let first = range(of: "Same line", in: old)
        let second = range(of: "Same line", in: old, occurrence: 1)

        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "second", start: second.lowerBound, end: second.upperBound)], from: old, into: new),
            .moved(["second": range(of: "Same line", in: new, occurrence: 1)]),
            "the old text's own surroundings (\"B. \" before it) say which copy the Margin was on"
        )
        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "first", start: first.lowerBound, end: first.upperBound)], from: old, into: new),
            .moved(["first": range(of: "Same line", in: new)])
        )
        XCTAssertEqual(
            StructuredDocumentMigration.place([
                Anchor(id: "first", start: first.lowerBound, end: first.upperBound),
                Anchor(id: "second", start: second.lowerBound, end: second.upperBound),
            ], from: old, into: new),
            .moved(["first": range(of: "Same line", in: new), "second": range(of: "Same line", in: new, occurrence: 1)]),
            "two Margins on the two copies each keep their own copy"
        )
    }

    func testOneTiedMarginKeepsTheWholeItemOnItsOldExtraction() {
        let old = "A. Same line.\nB. Same line.\nC. Unique words here."
        let new = "Top\n" + old
        let first = range(of: "Same line", in: old)
        let unique = range(of: "Unique words", in: old)
        let outcome = StructuredDocumentMigration.place([
            Anchor(id: "tied", start: first.lowerBound, end: first.upperBound, before: " ", after: "."),
            Anchor(id: "fine", start: unique.lowerBound, end: unique.upperBound),
        ], from: old, into: new)
        XCTAssertEqual(outcome, .stays(unplaced: ["tied"]), "one Margin that cannot be placed keeps every Margin where it is")
    }
}
