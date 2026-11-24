import XCTest
@testable import SessionKit

final class NowPinnedSlotTests: XCTestCase {
    func testSpeechAskTakesTheSlotOnlyWhenNothingElseHoldsIt() {
        for friend in [false, true] {
            for footnote in [false, true] {
                for locked in [false, true] {
                    let slot = NowPinnedSlot(friendsMarginCardShowing: friend, footnoteCardShowing: footnote, recordingIsLocked: locked)
                    XCTAssertEqual(slot.isFreeForSpeechAsk, !friend && !footnote && !locked,
                                   "friend \(friend), footnote \(footnote), locked \(locked)")
                }
            }
        }
    }
}
