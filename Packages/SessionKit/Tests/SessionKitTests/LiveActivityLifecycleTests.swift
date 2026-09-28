import XCTest
@testable import SessionKit

/// C3 M1: the Live Activity stayed on the Lock Screen long after listening stopped.
final class LiveActivityLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let limit = LiveActivityLifecycle.pausedIdleLimit

    func testListeningCarriesNoStaleDateSoPlaybackPublishesNothingExtra() {
        var lifecycle = LiveActivityLifecycle()
        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start), .show(staleDate: nil))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start.addingTimeInterval(3 * limit)),
            .show(staleDate: nil),
            "hours of playback never go stale"
        )
        XCTAssertNil(lifecycle.idleDeadline)
    }

    func testPausedActivityCarriesAStaleDateAndEndsAfterTheIdleLimit() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        let pausedAt = start.addingTimeInterval(600)
        let deadline = pausedAt.addingTimeInterval(limit)

        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: pausedAt), .show(staleDate: deadline))
        XCTAssertEqual(lifecycle.idleDeadline, deadline)
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: pausedAt.addingTimeInterval(limit - 1)),
            .show(staleDate: deadline),
            "refreshing while paused keeps the original deadline"
        )
        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: deadline), .end(.idleLimit))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: deadline.addingTimeInterval(60)),
            .hidden(.idleLimit),
            "a later refresh (the app returning to the foreground) doesn't bring it back"
        )
        XCTAssertNil(lifecycle.idleDeadline)
    }

    func testAppReturningAfterTheDeadlineEndsTheActivityOnItsFirstRefresh() {
        var lifecycle = LiveActivityLifecycle()
        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start), .show(staleDate: start.addingTimeInterval(limit)))
        // The process was suspended; the next refresh arrives two hours later.
        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(7_200)), .end(.idleLimit))
    }

    func testResumingRestartsTheIdleClockForTheNextPause() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(limit)), .end(.idleLimit))

        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start.addingTimeInterval(limit + 10)), .show(staleDate: nil))
        let secondPause = start.addingTimeInterval(limit + 100)
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: secondPause),
            .show(staleDate: secondPause.addingTimeInterval(limit))
        )
    }

    func testRecordingAMarginWhileTheSourceIsPausedIsListening() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: true, isPaused: true, now: start.addingTimeInterval(limit + 1)),
            .show(staleDate: nil),
            "a long spoken Margin never times the card out"
        )
    }

    func testSwitchingSessionsWhilePausedStartsAFreshClock() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        let later = start.addingTimeInterval(limit - 60)
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s2", isListening: false, isPaused: true, now: later),
            .show(staleDate: later.addingTimeInterval(limit))
        )
    }

    func testInterruptionThatSaysNotToResumeEndsAPausedActivity() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        // Another app (Spotify, Music) takes the audio: the app pauses, then the interruption ends without resume.
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(1))
        XCTAssertEqual(lifecycle.audioInterruptionEnded(shouldResume: false), .end(.interruptionWithoutResume))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(2)),
            .hidden(.interruptionWithoutResume)
        )
        XCTAssertNil(lifecycle.audioInterruptionEnded(shouldResume: false), "ending twice does nothing")
    }

    func testPhoneCallThatEndsWithResumeKeepsTheActivity() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        let callStarted = start.addingTimeInterval(1)
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: callStarted),
            .show(staleDate: callStarted.addingTimeInterval(limit))
        )
        XCTAssertNil(lifecycle.audioInterruptionEnded(shouldResume: true))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: callStarted.addingTimeInterval(300)),
            .show(staleDate: callStarted.addingTimeInterval(limit)),
            "still shown after the call, ready to resume"
        )
    }

    func testInterruptionWhileListeningOrWithoutASessionChangesNothing() {
        var lifecycle = LiveActivityLifecycle()
        XCTAssertNil(lifecycle.audioInterruptionEnded(shouldResume: false), "no session")
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        XCTAssertNil(lifecycle.audioInterruptionEnded(shouldResume: false), "already playing again")
    }
}
