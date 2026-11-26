import SessionKit
import XCTest

final class ReplyBoxCheckGateTests: XCTestCase {
    /// The Test Desk's run on #5397: a podcast-only sender, or one who chose "Use iOS Voice", never accepts the voice
    /// Terms, and their friends' answers never arrived. Nothing about those Terms may hold a check back.
    func testASenderWhoNeverAcceptedTheVoiceTermsStillCollectsAnswers() {
        XCTAssertTrue(ReplyBoxCheckGate.mayCheck(termsSheetShowing: false, agreedToLinksWithAnswers: true))
    }

    func testNoCheckWhileTheTermsSheetIsOnScreen() {
        XCTAssertFalse(ReplyBoxCheckGate.mayCheck(termsSheetShowing: true, agreedToLinksWithAnswers: true))
    }

    func testNoCheckBeforeTheListenerAgreedToLinksThatTakeAnswers() {
        XCTAssertFalse(ReplyBoxCheckGate.mayCheck(termsSheetShowing: false, agreedToLinksWithAnswers: false))
    }
}
