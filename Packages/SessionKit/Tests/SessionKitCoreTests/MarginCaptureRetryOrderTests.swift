import XCTest
@testable import SessionKit

/// What can happen between Try again's stop being sent and its answer: each test fails if the restart can run ahead of
/// the stop, run twice, or run for a recording that has ended.
@MainActor
final class MarginCaptureRetryOrderTests: XCTestCase {
    private var answers: [@MainActor () -> Void] = []
    private var restarts = 0

    private func tap(_ order: MarginCaptureRetryOrder) {
        order.begin(stop: { answers.append($0) }) { [self] in restarts += 1 }
    }

    func testTheStepWaitsForTheStopsAnswer() {
        let order = MarginCaptureRetryOrder()
        tap(order)
        XCTAssertEqual(restarts, 0)
        XCTAssertTrue(order.isWaiting)
        answers[0]()
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(order.isWaiting)
    }

    func testAStopThatAnswersAtOnceRunsTheStepBeforeBeginReturns() {
        let order = MarginCaptureRetryOrder()
        order.begin(stop: { $0() }) { [self] in restarts += 1 }
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(order.isWaiting)
    }

    func testASecondTapWhileWaitingAddsNothing() {
        let order = MarginCaptureRetryOrder()
        tap(order)
        tap(order)
        XCTAssertEqual(answers.count, 1, "no second stop")
        answers[0]()
        XCTAssertEqual(restarts, 1, "no second restart")
    }

    func testARecordingThatEndsWhileWaitingIsNotRestarted() {
        let order = MarginCaptureRetryOrder()
        tap(order)
        order.cancel()
        XCTAssertFalse(order.isWaiting)
        answers[0]()
        XCTAssertEqual(restarts, 0)
    }

    func testALateAnswerCannotRestartTheNextRecording() {
        let order = MarginCaptureRetryOrder()
        tap(order)
        order.cancel()
        tap(order)
        answers[0]() // the ended recording's stop answers while the next one waits
        XCTAssertEqual(restarts, 0)
        XCTAssertTrue(order.isWaiting)
        answers[1]()
        XCTAssertEqual(restarts, 1)
    }

    func testAnAnswerThatComesTwiceRestartsOnce() {
        let order = MarginCaptureRetryOrder()
        tap(order)
        answers[0]()
        answers[0]()
        XCTAssertEqual(restarts, 1)
    }
}
