import XCTest
@testable import SpokenMarginsApp

final class Build23ExperiencePolishTests: XCTestCase {
    func testCompactLibraryUsesWrappedComposition() {
        XCTAssertEqual(
            Build23ExperiencePolishLayout.libraryComposition(
                isCompactWidth: true,
                isAccessibilitySize: false
            ),
            .wrapped
        )
    }

    func testAccessibilityDynamicTypeUsesWrappedCompositionAtRegularWidth() {
        XCTAssertEqual(
            Build23ExperiencePolishLayout.libraryComposition(
                isCompactWidth: false,
                isAccessibilitySize: true
            ),
            .wrapped
        )
    }

    func testRegularWidthAtStandardDynamicTypeKeepsHorizontalComposition() {
        XCTAssertEqual(
            Build23ExperiencePolishLayout.libraryComposition(
                isCompactWidth: false,
                isAccessibilitySize: false
            ),
            .horizontal
        )
    }

    func testAddSourceKeepsPositiveBottomClearance() {
        XCTAssertGreaterThan(Build23ExperiencePolishLayout.addSourceBottomClearance, 0)
        XCTAssertLessThanOrEqual(Build23ExperiencePolishLayout.addSourceBottomClearance, 64)
    }

    func testRootContentClearanceTracksPersistentMiniPlayerVisibility() {
        XCTAssertEqual(
            Build23ExperiencePolishLayout.rootContentBottomClearance(
                showsPersistentMiniPlayer: false
            ),
            0
        )
        XCTAssertEqual(
            Build23ExperiencePolishLayout.rootContentBottomClearance(
                showsPersistentMiniPlayer: true
            ),
            Build23ExperiencePolishLayout.persistentMiniPlayerContentClearance
        )
        XCTAssertGreaterThan(Build23ExperiencePolishLayout.persistentMiniPlayerContentClearance, 0)
    }
}
