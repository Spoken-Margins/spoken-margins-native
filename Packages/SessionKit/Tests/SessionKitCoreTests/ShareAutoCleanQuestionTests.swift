import XCTest
@testable import SessionKit

/// The first-run "Remove ums and long pauses?" question asks only when it can be true (#3792).
final class ShareAutoCleanQuestionTests: XCTestCase {
    func testAsksOnlyWhenNoDecisionIsRecordedOnAnOrdinaryShareWithACleanableMargin() {
        XCTAssertTrue(ShareAutoCleanQuestion.asks(hasRecordedDecision: false, isReplyBack: false, anyIncludedCanBeCleaned: true))
    }

    func testNeverAsksOnTheReplySheet() {
        XCTAssertFalse(ShareAutoCleanQuestion.asks(hasRecordedDecision: false, isReplyBack: true, anyIncludedCanBeCleaned: true))
    }

    func testNeverAsksWhenNothingIncludedCouldBeCleaned() {
        // A Margin with no word-level timing: nothing can be removed, so the question is moot.
        XCTAssertFalse(ShareAutoCleanQuestion.asks(hasRecordedDecision: false, isReplyBack: false, anyIncludedCanBeCleaned: false))
    }

    func testNeverAsksAgainOnceADecisionIsRecorded() {
        for replyBack in [false, true] {
            for cleanable in [false, true] {
                XCTAssertFalse(ShareAutoCleanQuestion.asks(hasRecordedDecision: true, isReplyBack: replyBack, anyIncludedCanBeCleaned: cleanable))
            }
        }
    }
}
