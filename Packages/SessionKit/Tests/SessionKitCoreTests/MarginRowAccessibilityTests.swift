import XCTest
@testable import SessionKit

/// The Margins tab row's VoiceOver value (#4180, PR 3): the star and the photo are both pictures, so both are said.
final class MarginRowAccessibilityTests: XCTestCase {
    func testTheValueSaysTheStarAndThePhotoInEveryCombination() {
        let cases: [(starred: Bool, hasPhoto: Bool, expected: String)] = [
            (false, false, ""),
            (true, false, "Starred for sharing"),
            (false, true, "with a photo"),
            (true, true, "Starred for sharing, with a photo"),
        ]
        for row in cases {
            XCTAssertEqual(
                MarginRowAccessibility.value(starred: row.starred, hasPhoto: row.hasPhoto),
                row.expected,
                "starred: \(row.starred), hasPhoto: \(row.hasPhoto)"
            )
        }
    }

    func testThePhotoWordsAreTheOnesTheOtherRowsUse() {
        XCTAssertEqual(
            MarginRowAccessibility.value(starred: false, hasPhoto: true),
            LiveSessionPhotoMargin.rowAccessibilityValue
        )
    }
}
