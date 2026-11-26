import XCTest
@testable import SessionKit

final class TimelineTextPresentationTests: XCTestCase {
    func testTimelineTextExcerptCollapsesWhitespaceAndBoundsLongMargins() {
        let longMargin = Array(repeating: "This is a deliberately long spoken margin", count: 20)
            .joined(separator: " \n\t")

        let excerpt = TimelineTextPresentation.excerpt(longMargin, characterLimit: 80)

        XCTAssertLessThanOrEqual(excerpt.count, 81)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertFalse(excerpt.contains("\n"))
        XCTAssertFalse(excerpt.contains("\t"))
        XCTAssertFalse(excerpt.hasSuffix(" margin…"), "The excerpt should use the last complete word inside its limit.")

        // A hard cut at 80 characters ends mid-word and also avoids " margin…", so check where the excerpt stops.
        let normalized = longMargin.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let kept = String(excerpt.dropLast())
        XCTAssertTrue(normalized.hasPrefix(kept), "The excerpt is the start of the Margin, whitespace collapsed.")
        XCTAssertEqual(normalized[normalized.index(normalized.startIndex, offsetBy: kept.count)], " ", "The excerpt ends where a word ends, not inside one.")
    }

    func testTimelineTextExcerptCutsAtWordBoundariesForNeighbouringInputs() {
        let cases: [(text: String, limit: Int, expected: String)] = [
            ("", 10, ""),
            ("short", 10, "short"),
            ("exactly ten", 11, "exactly ten"),
            ("aaaa bbbb cccc", 9, "aaaa bbbb…"),
            ("aaaa bbbb cccc", 10, "aaaa bbbb…"),
            ("aaaa bbbb cccc", 11, "aaaa bbbb…"),
            ("supercalifragilistic", 8, "supercal…"),
            ("  leading   and\ttrailing  ", 100, "leading and trailing"),
            ("caf\u{E9} \u{FC}ni\u{EF}code w\u{F6}rds", 9, "caf\u{E9}…"),
            ("cafe\u{301} \u{FC}ni\u{EF}code w\u{F6}rds", 9, "cafe\u{301}…")
        ]
        for (text, limit, expected) in cases {
            XCTAssertEqual(TimelineTextPresentation.excerpt(text, characterLimit: limit), expected, "\(text.debugDescription) at \(limit)")
        }
    }
}
