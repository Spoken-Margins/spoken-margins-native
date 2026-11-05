import XCTest
@testable import SessionKit

/// #1507: Share on the playback screen opens the Share Margins sheet on its review, so Share is two taps away.
final class ShareSheetEntryTests: XCTestCase {
    func testPlaybackEntryStartsOnReviewWhenSomethingIsSelected() {
        XCTAssertTrue(ShareSheetEntry.reviewDefaults.startsOnReview(includedCount: 1))
        XCTAssertTrue(ShareSheetEntry.reviewDefaults.startsOnReview(includedCount: 12))
    }

    func testPlaybackEntryStartsOnTheChoiceWhenNothingIsSelected() {
        XCTAssertFalse(ShareSheetEntry.reviewDefaults.startsOnReview(includedCount: 0))
    }

    func testMarginsTabAndExportScreenKeepStartingOnTheChoice() {
        for count in [0, 1, 5] {
            XCTAssertFalse(ShareSheetEntry.chooseMargins.startsOnReview(includedCount: count))
        }
    }
}
