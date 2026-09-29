import XCTest
@testable import SessionKit

final class StructuredDocumentMigrationTests: XCTestCase {
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

    func testMarginsMoveToTheSameWordsWhenTheyAppearOnce() {
        let old = "Methods\nWe measured sleep.\nResults\nSleep improved."
        let new = "J Biol 12\n\nMethods\n\nWe measured sleep.\n\nResults\n\nSleep improved.\n\nReferences\n\n[1] A. B. 2020."
        let a = range(of: "measured sleep", in: old)
        let b = range(of: "Sleep improved", in: old)
        let outcome = StructuredDocumentMigration.place([
            Anchor(id: "a", start: a.lowerBound, end: a.upperBound),
            Anchor(id: "b", start: b.lowerBound, end: b.upperBound),
        ], from: old, into: new)
        XCTAssertEqual(outcome, .moved(["a": range(of: "measured sleep", in: new), "b": range(of: "Sleep improved", in: new)]))
    }

    func testRepeatedWordsAreSettledByContextOrLeftWhereTheyAre() {
        let old = "The dose was low. Later the dose was high."
        let new = "Header\n\nThe dose was low. Later the dose was high."
        let second = range(of: "the dose", in: old)
        // "the dose" (lower case) appears once in both; "dose was" twice.
        let dose = range(of: "dose was", in: old, occurrence: 1)
        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "d", start: dose.lowerBound, end: dose.upperBound, before: "Later the ", after: " high.")], from: old, into: new),
            .moved(["d": range(of: "dose was", in: new, occurrence: 1)])
        )
        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "s", start: second.lowerBound, end: second.upperBound)], from: old, into: new),
            .moved(["s": range(of: "the dose", in: new)])
        )
        // Identical repeats with identical surroundings: no way to tell, so it stays.
        let twice = "Same line.\nSame line."
        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "t", start: 0, end: 9, before: "x", after: "y")], from: twice, into: "Top\n" + twice),
            .stays(unplaced: ["t"])
        )
    }

    func testChangedWordsLeaveTheItemWhereItIs() {
        // v1 cut a running head out of a paragraph that crossed a page; v2 keeps it.
        let old = "the effect held across cohorts"
        let new = "the effect held\nJ Biol 12\nacross cohorts"
        XCTAssertEqual(
            StructuredDocumentMigration.place([Anchor(id: "m", start: 4, end: 30)], from: old, into: new),
            .stays(unplaced: ["m"])
        )
    }

    func testPositionsFollowTheTextAfterThem() {
        let old = "Intro text here.\nThe middle of the paper starts here and goes on for a while longer."
        let new = "Header\n\nIntro text here.\n\nThe middle of the paper starts here and goes on for a while longer."
        let middle = range(of: "The middle", in: old).lowerBound
        XCTAssertEqual(StructuredDocumentMigration.placePosition(middle, from: old, into: new), range(of: "The middle", in: new).lowerBound)
        XCTAssertEqual(StructuredDocumentMigration.placePosition(0, from: old, into: new), 0)
        XCTAssertEqual(StructuredDocumentMigration.placePosition(old.count, from: old, into: new), new.count)
        XCTAssertNil(StructuredDocumentMigration.placePosition(middle, from: old, into: "Something else entirely, with no shared text at all."))
    }
}
