import XCTest
@testable import SessionKit

/// #3769: one order for a Library folder's files. A table of neighbouring inputs: numbers, case, Unicode forms, spaces and
/// punctuation, prefixes, and paths whose parts compare differently from the whole string.
final class NaturalPathOrderTests: XCTestCase {
    private func sorted(_ paths: [String]) -> [String] {
        paths.sorted { NaturalPathOrder.areInIncreasingOrder($0, $1) }
    }

    func testNumbersCompareAsNumbers() {
        XCTAssertEqual(sorted(["10.pdf", "2.pdf", "1.pdf"]), ["1.pdf", "2.pdf", "10.pdf"])
        XCTAssertEqual(sorted(["Chapter 10.pdf", "Chapter 9.pdf", "Chapter 1.pdf"]), ["Chapter 1.pdf", "Chapter 9.pdf", "Chapter 10.pdf"])
        XCTAssertEqual(sorted(["x/10.pdf", "x/2.pdf"]), ["x/2.pdf", "x/10.pdf"])
    }

    func testTheSameLettersInDifferentCaseSitTogether() {
        let result = sorted(["b.pdf", "A.pdf", "a.pdf", "c.pdf"])
        XCTAssertEqual(Set(result.prefix(2)), ["a.pdf", "A.pdf"], "a and A are neighbours, and b and c follow")
        XCTAssertEqual(Array(result.suffix(2)), ["b.pdf", "c.pdf"])
    }

    func testPrecomposedAndDecomposedNamesAreTheSamePath() {
        let precomposed = "caf\u{00E9}/1.pdf"
        let decomposed = "cafe\u{0301}/1.pdf"
        XCTAssertEqual(NaturalPathOrder.compare(precomposed, decomposed), .orderedSame)
        XCTAssertEqual(NaturalPathOrder.components(decomposed), ["caf\u{00E9}", "1.pdf"], "components come back in NFC")
    }

    func testAShorterPathThatIsAPrefixComesFirst() {
        XCTAssertEqual(NaturalPathOrder.compare("a", "a/b.pdf"), .orderedAscending)
        XCTAssertEqual(NaturalPathOrder.compare("a/b.pdf", "a"), .orderedDescending)
        // Parts are compared whole: the folder "a" comes before the file "a.pdf", and "b" before "b.pdf".
        XCTAssertEqual(sorted(["a.pdf", "a/b.pdf", "a/b/c.pdf"]), ["a/b/c.pdf", "a/b.pdf", "a.pdf"])
    }

    func testPartsAreComparedOneAtATimeNotAsOneString() {
        // As whole strings ' ' sorts before '/', which would put "a b/x.pdf" first; by components "a" < "a b".
        XCTAssertEqual(NaturalPathOrder.compare("a/z.pdf", "a b/x.pdf"), .orderedAscending)
        XCTAssertEqual(NaturalPathOrder.compare("Disc 1/x.pdf", "Disc 1.5/y.pdf"), .orderedAscending)
        XCTAssertEqual(NaturalPathOrder.compare("Disc 1.5/y.pdf", "Disc 2/a.pdf"), .orderedAscending)
    }

    func testSpacesAndPunctuationGiveAStrictOrderBothWays() {
        let names = ["a b.pdf", "a-b.pdf", "a_b.pdf", "a.b.pdf", "ab.pdf", "a  b.pdf", "A B.pdf"]
        for left in names {
            for right in names where left != right {
                let forward = NaturalPathOrder.compare(left, right)
                let backward = NaturalPathOrder.compare(right, left)
                XCTAssertNotEqual(forward, .orderedSame, "\(left) vs \(right) must not tie")
                XCTAssertEqual(forward == .orderedAscending, backward == .orderedDescending, "\(left) vs \(right) is antisymmetric")
            }
        }
    }

    func testEmptyAndDoubledSlashesAreIgnored() {
        XCTAssertEqual(NaturalPathOrder.compare("a//b.pdf", "a/b.pdf"), .orderedSame)
        XCTAssertEqual(NaturalPathOrder.compare("/a/b.pdf", "a/b.pdf"), .orderedSame)
        XCTAssertEqual(NaturalPathOrder.compare("", ""), .orderedSame)
        XCTAssertEqual(NaturalPathOrder.compare("", "a"), .orderedAscending)
    }

    func testAVeryLongPathStillOrders() {
        let long = String(repeating: "folder/", count: 200) + "1.pdf"
        XCTAssertEqual(NaturalPathOrder.compare(long, long + "x"), .orderedAscending)
    }

    func testTheSameOrderOnEveryRun() {
        let paths = ["10.pdf", "2.pdf", "a.pdf", "A.pdf", "Disc 1/x.pdf", "Disc 1.5/y.pdf", "caf\u{00E9}.pdf", "z/1.pdf"]
        XCTAssertEqual(sorted(paths), sorted(paths.reversed()))
        XCTAssertEqual(sorted(paths), sorted(paths.shuffled()))
    }
}
