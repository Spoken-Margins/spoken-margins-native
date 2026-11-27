import XCTest
@testable import SessionKit

/// The Library's queue entry waits for the swipe to settle before it shows (#5360).
final class QueueEntryRevealTests: XCTestCase {
    func testFirstAddWaitsForTheSwipeToSettleBeforeShowing() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: false)
        guard case let .showAfter(delay, generation) = reveal.queueChanged(isQueued: true) else {
            return XCTFail("the first add must wait, not show at once")
        }
        XCTAssertEqual(delay, QueueEntryReveal.settleDelay)
        XCTAssertGreaterThanOrEqual(delay, .milliseconds(350), "shorter than a swipe's spring-back brings the jump back")
        XCTAssertFalse(reveal.showsEntry(isQueued: true), "nothing may grow the list while the swiped row slides back")
        XCTAssertTrue(reveal.settleFinished(generation: generation))
        XCTAssertTrue(reveal.showsEntry(isQueued: true))
    }

    func testQueueThatEmptiesInsideTheWaitNeverShows() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: false)
        guard case let .showAfter(_, generation) = reveal.queueChanged(isQueued: true) else { return XCTFail() }
        XCTAssertEqual(reveal.queueChanged(isQueued: false), .hideNow)
        XCTAssertFalse(reveal.settleFinished(generation: generation))
        XCTAssertFalse(reveal.showsEntry(isQueued: false))
    }

    func testOnlyTheLatestWaitShows() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: false)
        guard case let .showAfter(_, first) = reveal.queueChanged(isQueued: true) else { return XCTFail() }
        _ = reveal.queueChanged(isQueued: false)
        guard case let .showAfter(_, second) = reveal.queueChanged(isQueued: true) else { return XCTFail() }
        XCTAssertFalse(reveal.settleFinished(generation: first))
        XCTAssertFalse(reveal.showsEntry(isQueued: true))
        XCTAssertTrue(reveal.settleFinished(generation: second))
        XCTAssertFalse(reveal.settleFinished(generation: second), "a finished wait comes in once")
    }

    func testFirstDrawWithTheNewQueueBeforeTheChangeIsReportedShowsNothing() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: false)
        // SwiftUI draws the body with the queue's new value before onChange runs.
        XCTAssertFalse(reveal.showsEntry(isQueued: true), "a one-frame entry is the jump")
    }

    func testQueueHoldingItemsWhenTheLibraryAppearsShowsAtOnce() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: true)
        XCTAssertTrue(reveal.showsEntry(isQueued: true))
        XCTAssertFalse(reveal.showsEntry(isQueued: false))
    }

    func testAppearingAgainCancelsAWaitAndShowsAtOnce() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: false)
        guard case let .showAfter(_, generation) = reveal.queueChanged(isQueued: true) else { return XCTFail() }
        reveal.appeared(isQueued: true)
        XCTAssertTrue(reveal.showsEntry(isQueued: true))
        XCTAssertFalse(reveal.settleFinished(generation: generation))
    }

    func testEmptyingAShownQueueHidesAtOnce() {
        var reveal = QueueEntryReveal()
        reveal.appeared(isQueued: true)
        XCTAssertEqual(reveal.queueChanged(isQueued: false), .hideNow)
        XCTAssertFalse(reveal.showsEntry(isQueued: false))
    }
}
