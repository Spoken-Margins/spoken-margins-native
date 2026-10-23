import XCTest
@testable import SessionKit

/// #1820: the one-time "Supertonic is now a free download" card, for listeners whose saved voice is Supertonic.
final class SupertonicDownloadNoticePolicyTests: XCTestCase {
    private func decide(supertonic: Bool = true, installed: Bool = false, seen: Bool = false, sheet: Bool = false)
        -> SupertonicDownloadNoticePolicy.Decision {
        SupertonicDownloadNoticePolicy.decide(savedVoiceIsSupertonic: supertonic, modelInstalled: installed, hasSeen: seen, anotherSheetShowing: sheet)
    }

    func testAListenerWhoseVoiceIsSupertonicAndHasNotDownloadedItSeesTheCard() {
        XCTAssertEqual(decide(), .show)
    }

    func testTheCardShowsOnce() {
        XCTAssertEqual(decide(seen: true), .done)
        XCTAssertEqual(decide(installed: true, seen: true), .done)
        XCTAssertEqual(decide(supertonic: false, seen: true), .done)
    }

    func testAListenerOnTheIOSVoiceIsNotToldAboutSupertonicButMayBeLater() {
        // They may pick James later, on this launch or the next; the card waits for that.
        XCTAssertEqual(decide(supertonic: false), .wait)
    }

    func testAnotherSheetMakesItWaitForTheNextLaunch() {
        XCTAssertEqual(decide(sheet: true), .wait)
    }

    func testOnceDownloadedTheCardIsNeverNeededEvenAfterARemove() {
        XCTAssertEqual(decide(installed: true), .settle)
        XCTAssertEqual(decide(supertonic: false, installed: true), .settle)
        XCTAssertEqual(decide(installed: true, sheet: true), .settle)
    }
}
