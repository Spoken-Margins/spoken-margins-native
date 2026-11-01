import Foundation
import XCTest
@testable import SessionKit

/// #3171 (#3032 slice 4): "a start is pending, which attempt, until when" is one value, so a resume cannot leave a half-cleared
/// start behind. Each row is a way the engine's six loose fields used to disagree.
final class PlaybackStartAttemptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func attempt() -> PlaybackStartAttempt { PlaybackStartAttempt(timeout: 10) }

    func testBeginCountsUpAndIsTheCurrentAttempt() {
        var start = attempt()
        XCTAssertEqual(start.currentAttemptId, 0)
        XCTAssertEqual(start.begin(), 1)
        XCTAssertEqual(start.currentAttemptId, 1)
        XCTAssertEqual(start.begin(), 2)
        XCTAssertEqual(start.currentAttemptId, 2)
    }

    func testPendingStartWaitsUntilItsDeadlineThenExpires() {
        var start = attempt()
        let id = start.begin()
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertFalse(start.expired(now: at(9.9)))
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(9.9), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertTrue(start.expired(now: at(10)))
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(10), awaitingRenderedAudio: { false }), .expired)
    }

    func testNothingIsExpiredBeforeAStartIsPending() {
        var start = attempt()
        start.begin()
        XCTAssertFalse(start.expired(now: at(1_000)))
    }

    func testConfirmedClearsThePendingStateSoItCannotExpireLater() {
        var start = attempt()
        let id = start.begin()
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { false })
        start.confirmed()
        XCTAssertFalse(start.expired(now: at(60)))
        // The same target and attempt pending again is a new wait with a fresh deadline, not a timeout of the old one.
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(60), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertFalse(start.expired(now: at(69)))
    }

    func testFailedStartIsRecoveredAsANewWait() {
        var start = attempt()
        let id = start.begin()
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { false })
        start.failed()
        XCTAssertEqual(start.currentAttemptId, id, "the counter survives a settled start; no active attempt, so the latest is current")
        XCTAssertFalse(start.expired(now: at(60)))
    }

    func testStaleAttemptIdFromAnEarlierStartNeverMatchesALaterOne() {
        var start = attempt()
        let first = start.begin()
        _ = start.observePending(targetId: "a", attemptId: first, now: at(0), awaitingRenderedAudio: { false })
        start.clear()
        let second = start.begin()
        XCTAssertNotEqual(first, second)
        // The earlier attempt id pending again is a different wait than the later one, so it gets its own deadline.
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: second, now: at(5), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: first, now: at(12), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertFalse(start.expired(now: at(21)))
        XCTAssertTrue(start.expired(now: at(22)))
    }

    func testStartReplacedByANewTargetStartsAFreshDeadline() {
        var start = attempt()
        let id = start.begin()
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { false })
        XCTAssertEqual(start.observePending(targetId: "b", attemptId: id, now: at(8), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertEqual(start.observePending(targetId: "b", attemptId: id, now: at(17), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertEqual(start.observePending(targetId: "b", attemptId: id, now: at(18), awaitingRenderedAudio: { false }), .expired)
    }

    func testRenderingAudioExtendsTheDeadlineUntilTheWaitCap() {
        var start = attempt()
        let id = start.begin()
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { true })
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(10), awaitingRenderedAudio: { true }), .waiting)
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(20), awaitingRenderedAudio: { true }), .waiting)
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(30), awaitingRenderedAudio: { true }), .waiting)
        // Four timeouts after the first wait the cap ends a start that never resolves (#235).
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(40), awaitingRenderedAudio: { true }), .expired)
    }

    func testRenderQuestionIsOnlyAskedAfterTheDeadline() {
        var start = attempt()
        let id = start.begin()
        var asked = 0
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { asked += 1; return true })
        _ = start.observePending(targetId: "a", attemptId: id, now: at(5), awaitingRenderedAudio: { asked += 1; return true })
        XCTAssertEqual(asked, 0)
        _ = start.observePending(targetId: "a", attemptId: id, now: at(10), awaitingRenderedAudio: { asked += 1; return true })
        XCTAssertEqual(asked, 1)
    }

    func testRestartedTransportWaitsAgainButKeepsTheOriginalWaitCap() {
        var start = attempt()
        let id = start.begin()
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { true })
        start.restarted(targetId: "a", attemptId: id, now: at(10))
        XCTAssertFalse(start.expired(now: at(19)))
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(20), awaitingRenderedAudio: { true }), .waiting)
        XCTAssertEqual(start.observePending(targetId: "a", attemptId: id, now: at(40), awaitingRenderedAudio: { true }), .expired)
    }

    func testMovedToAnotherTargetForgetsTheOldWait() {
        var start = attempt()
        let id = start.begin()
        _ = start.observePending(targetId: "a", attemptId: id, now: at(0), awaitingRenderedAudio: { false })
        start.movedToAnotherTarget()
        XCTAssertFalse(start.expired(now: at(60)))
        XCTAssertEqual(start.currentAttemptId, id, "the attempt stays active across the move")
        XCTAssertEqual(start.observePending(targetId: "b", attemptId: id, now: at(60), awaitingRenderedAudio: { false }), .waiting)
        XCTAssertFalse(start.expired(now: at(69)))
    }
}
