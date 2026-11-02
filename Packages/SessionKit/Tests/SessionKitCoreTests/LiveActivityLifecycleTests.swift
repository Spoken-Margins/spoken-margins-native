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
        XCTAssertEqual(lifecycle.audioInterruptionEnded(.audioStaysStopped), .end(.interruptionWithoutResume))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(2)),
            .hidden(.interruptionWithoutResume)
        )
        XCTAssertNil(lifecycle.audioInterruptionEnded(.audioStaysStopped), "ending twice does nothing")
    }

    func testPhoneCallThatEndsWithResumeKeepsTheActivity() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        let callStarted = start.addingTimeInterval(1)
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: callStarted),
            .show(staleDate: callStarted.addingTimeInterval(limit))
        )
        XCTAssertNil(lifecycle.audioInterruptionEnded(.audioMayStart))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: callStarted.addingTimeInterval(300)),
            .show(staleDate: callStarted.addingTimeInterval(limit)),
            "still shown after the call, ready to resume"
        )
    }

    // MARK: Owner decision #193 (option 2): hand the removal to iOS after a locked pause.

    private let grace = LiveActivityLifecycle.lockedPauseGrace

    func testLockedPauseHandsTheRemovalToIOSAfterTheGrace() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        let pausedAt = start.addingTimeInterval(60)
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: pausedAt)

        XCTAssertEqual(lifecycle.scheduleHandOff(appInBackground: true, now: pausedAt), pausedAt.addingTimeInterval(grace))
        XCTAssertNil(lifecycle.handOffIfDue(appInBackground: true, now: pausedAt.addingTimeInterval(grace - 1)), "still in the grace")
        XCTAssertEqual(lifecycle.handOffIfDue(appInBackground: true, now: pausedAt.addingTimeInterval(grace)), pausedAt.addingTimeInterval(limit),
                       "iOS removes it at the idle deadline")
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: pausedAt.addingTimeInterval(grace + 5)),
            .hidden(.handedOffToSystem),
            "a later paused refresh doesn't request a new card"
        )
        XCTAssertNil(lifecycle.idleDeadline, "no in-process timer once iOS owns the removal")
        XCTAssertEqual(lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: pausedAt.addingTimeInterval(120)), .show(staleDate: nil),
                       "resuming shows a card again")
    }

    func testQuickPauseAndResumeWithinTheGraceKeepsTheCard() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        XCTAssertNotNil(lifecycle.scheduleHandOff(appInBackground: true, now: start))
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start.addingTimeInterval(8))
        XCTAssertNil(lifecycle.handOffIfDue(appInBackground: true, now: start.addingTimeInterval(grace)), "resumed inside the grace")
    }

    func testPauseInTheForegroundOrReturningToTheAppDoesNotHandOff() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        XCTAssertNil(lifecycle.scheduleHandOff(appInBackground: false, now: start), "the app manages the card while it's open")
        XCTAssertNotNil(lifecycle.scheduleHandOff(appInBackground: true, now: start.addingTimeInterval(5)))
        lifecycle.appReturnedToForeground()
        XCTAssertNil(lifecycle.handOffIfDue(appInBackground: true, now: start.addingTimeInterval(60)))
    }

    func testInterruptionPausesNeverHandOff() {
        // A phone call: the interruption is reported, then the pause arrives.
        var call = LiveActivityLifecycle()
        _ = call.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        call.audioInterruptionBegan()
        _ = call.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(1))
        XCTAssertNil(call.scheduleHandOff(appInBackground: true, now: start.addingTimeInterval(1)))
        XCTAssertNil(call.handOffIfDue(appInBackground: true, now: start.addingTimeInterval(1 + grace)))
        XCTAssertEqual(
            call.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(600)),
            .show(staleDate: start.addingTimeInterval(1 + limit)),
            "the card stays for the listener to resume after the call"
        )

        // The pause can also arrive first; the interruption then cancels the scheduled hand-off.
        var spotify = LiveActivityLifecycle()
        _ = spotify.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        XCTAssertNotNil(spotify.scheduleHandOff(appInBackground: true, now: start))
        spotify.audioInterruptionBegan()
        XCTAssertNil(spotify.handOffIfDue(appInBackground: true, now: start.addingTimeInterval(grace)))

        // After resuming, the next ordinary locked pause hands off again.
        _ = call.observe(sessionId: "s1", isListening: true, isPaused: false, now: start.addingTimeInterval(700))
        let nextPause = start.addingTimeInterval(800)
        _ = call.observe(sessionId: "s1", isListening: false, isPaused: true, now: nextPause)
        XCTAssertEqual(call.scheduleHandOff(appInBackground: true, now: nextPause), nextPause.addingTimeInterval(grace))
    }

    // MARK: #245: another app took over the audio.

    func testAnotherAppPlayingEndsAPausedCardAtOnce() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        lifecycle.audioInterruptionBegan() // Spotify took the audio
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(1))
        XCTAssertTrue(lifecycle.isPausedCardOnScreen)
        XCTAssertEqual(lifecycle.otherAudioChecked(isOtherAudioPlaying: true, isPhoneCallActive: false), .end(.otherAudioTookOver))
        XCTAssertEqual(
            lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(6)),
            .hidden(.otherAudioTookOver)
        )
        XCTAssertFalse(lifecycle.isPausedCardOnScreen)
    }

    func testListenerPauseThenAnotherAppEndsTheCardToo() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        XCTAssertNil(lifecycle.otherAudioChecked(isOtherAudioPlaying: false, isPhoneCallActive: false), "nothing else playing yet")
        XCTAssertEqual(lifecycle.otherAudioChecked(isOtherAudioPlaying: true, isPhoneCallActive: false), .end(.otherAudioTookOver))
    }

    func testPhoneCallKeepsTheCardEvenWhenOtherAudioIsReported() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        lifecycle.audioInterruptionBegan()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start.addingTimeInterval(1))
        XCTAssertNil(lifecycle.otherAudioChecked(isOtherAudioPlaying: true, isPhoneCallActive: true))
        XCTAssertTrue(lifecycle.isPausedCardOnScreen, "still there to resume after the call")
    }

    func testAHandedOffCardIsDismissedWhenAnotherAppPlays() {
        var lifecycle = LiveActivityLifecycle()
        _ = lifecycle.observe(sessionId: "s1", isListening: false, isPaused: true, now: start)
        _ = lifecycle.scheduleHandOff(appInBackground: true, now: start)
        XCTAssertNotNil(lifecycle.handOffIfDue(appInBackground: true, now: start.addingTimeInterval(grace)))
        XCTAssertTrue(lifecycle.isPausedCardOnScreen, "ended, but on screen until the deadline")
        XCTAssertEqual(lifecycle.otherAudioChecked(isOtherAudioPlaying: true, isPhoneCallActive: false), .end(.otherAudioTookOver))
    }

    func testOtherAudioWhileWeArePlayingOrWithNoSessionChangesNothing() {
        var lifecycle = LiveActivityLifecycle()
        XCTAssertNil(lifecycle.otherAudioChecked(isOtherAudioPlaying: true, isPhoneCallActive: false), "no session")
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        XCTAssertNil(lifecycle.otherAudioChecked(isOtherAudioPlaying: true, isPhoneCallActive: false), "mixing while we play")
    }

    func testInterruptionWhileListeningOrWithoutASessionChangesNothing() {
        var lifecycle = LiveActivityLifecycle()
        XCTAssertNil(lifecycle.audioInterruptionEnded(.audioStaysStopped), "no session")
        _ = lifecycle.observe(sessionId: "s1", isListening: true, isPaused: false, now: start)
        XCTAssertNil(lifecycle.audioInterruptionEnded(.audioStaysStopped), "already playing again")
    }
}
