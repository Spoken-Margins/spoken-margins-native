import XCTest
@testable import SessionKit

/// #5306: the Share Margins sheet and the Export screen each have one button to the other, for the same item.
final class ShareExportSwitchTests: XCTestCase {
    func testEachButtonNamesTheOtherDoor() {
        XCTAssertEqual(ShareExportSwitch.exportButtonTitle, "Export")
        XCTAssertEqual(ShareExportSwitch.shareButtonTitle, "Share")
        XCTAssertTrue(ShareExportSwitch.exportScreenIntro.hasSuffix("tap Share."))
    }

    func testAReplySheetOffersNoExport() {
        XCTAssertTrue(ShareExportSwitch.offersExport(isReplyBack: false))
        XCTAssertFalse(ShareExportSwitch.offersExport(isReplyBack: true))
    }

    func testExportStartsOnTheSessionTheSheetWasSharingFrom() {
        XCTAssertEqual(ShareExportSwitch.exportSessionId(sharingSessionId: "s2", itemSessionIdsNewestFirst: ["s3", "s2", "s1"]), "s2")
    }

    func testASessionFromAnotherItemFallsBackToThisItemsNewest() {
        XCTAssertEqual(ShareExportSwitch.exportSessionId(sharingSessionId: "other", itemSessionIdsNewestFirst: ["s3", "s1"]), "s3")
        XCTAssertEqual(ShareExportSwitch.exportSessionId(sharingSessionId: nil, itemSessionIdsNewestFirst: ["s3", "s1"]), "s3")
    }

    func testAnItemWithNoSessionHasNothingToExport() {
        XCTAssertNil(ShareExportSwitch.exportSessionId(sharingSessionId: "s1", itemSessionIdsNewestFirst: []))
        XCTAssertNil(ShareExportSwitch.exportSessionId(sharingSessionId: nil, itemSessionIdsNewestFirst: []))
    }
}
