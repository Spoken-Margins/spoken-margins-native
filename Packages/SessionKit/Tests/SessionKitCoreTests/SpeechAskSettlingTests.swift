import XCTest
@testable import SessionKit

/// #4715: held transcription leaves the speech ask's books only once it was retried or can no longer be.
final class SpeechAskSettlingTests: XCTestCase {
    /// Allow clears only the Margins whose retries were scheduled: one that started waiting meanwhile stays.
    func testOnlyTheSettledMarginsLeaveTheWaitingList() {
        let list = SpeechAskWaitingList(stored: ["s1::a", "s1::b", "s2::c"])
        let after = SpeechAskSettling.waiting(list, afterSettling: ["s1::a", "s1::b"])
        XCTAssertEqual(after.ids, ["s2::c"])
        XCTAssertTrue(after.hasWaitingMargin)
    }

    /// Nothing retried (no Library open yet): the list is kept whole for the next settle.
    func testAListNothingRetriedIsKeptWhole() {
        let list = SpeechAskWaitingList(stored: ["s1::a", "s1::b"])
        XCTAssertEqual(SpeechAskSettling.waiting(list, afterSettling: []).ids, ["s1::a", "s1::b"])
        XCTAssertEqual(SpeechAskSettling.waiting(list, afterSettling: ["s1::a", "s1::b"]).ids, [])
        XCTAssertEqual(SpeechAskSettling.waiting(list, afterSettling: ["s9::z"]).ids, ["s1::a", "s1::b"])
    }
}
