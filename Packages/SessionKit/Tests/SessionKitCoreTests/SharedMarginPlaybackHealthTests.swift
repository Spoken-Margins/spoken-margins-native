import Foundation
import XCTest
@testable import SessionKit

/// #941: a shared Margin said "Playing" with a Pause button as soon as Listen was tapped, and kept
/// saying it after its voice failed, because nothing checked the player afterwards. These are the
/// rows of the issue's table: what the screen may say for each thing the player can report.
final class SharedMarginPlaybackHealthTests: XCTestCase {
    private func health(at start: TimeInterval = 100) -> SharedMarginPlaybackHealth {
        SharedMarginPlaybackHealth(startedAt: start)
    }

    func testAskingToPlayIsLoadingNotPlaying() {
        var health = health()
        XCTAssertEqual(health.phase, .loading)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, at: 100.2), .loading)
        XCTAssertTrue(health.showsPause, "the listener can still cancel while it loads")
        XCTAssertEqual(health.nowPlayingRate(playerRate: 1.2), 0, "a requested rate is not playback")
    }

    func testAnAdvancingClockIsPlaying() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 0, at: 100.2)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0.2, at: 100.4), .playing)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0.4, at: 100.6), .playing)
        XCTAssertTrue(health.hasPlayed)
        XCTAssertEqual(health.nowPlayingRate(playerRate: 1.2), 1.2)
    }

    func testADecoderFailureIsFailedWhateverRateWasRequested() {
        // A real AVPlayer given a damaged file: failed=true, elapsed=0, duration=NaN, rate=1.
        var health = health()
        XCTAssertEqual(health.observe(playerFailed: true, clockSeconds: 0, at: 100.2), .failed(.unreadable))
        XCTAssertFalse(health.showsPause)
        XCTAssertEqual(health.nowPlayingRate(playerRate: 1), 0)
    }

    func testAFailureAfterPlayingStartedIsStillFailed() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 0.5, at: 100.5)
        XCTAssertEqual(health.observe(playerFailed: true, clockSeconds: 0.5, at: 100.7), .failed(.unreadable))
    }

    func testASlowStartStaysLoadingUntilTheClockMoves() {
        var health = health()
        for seconds in stride(from: 0.2, through: 6, by: 0.2) {
            XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, at: 100 + seconds), .loading, "at \(seconds)s")
        }
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0.3, at: 106.2), .playing)
    }

    func testAPlayerThatNeverAdvancesFailsAfterTheFirstSoundTimeout() {
        var health = health()
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, at: 109.9), .loading)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, at: 110), .failed(.noProgress))
        XCTAssertFalse(health.showsPause)
    }

    func testAClockThatStopsAfterPlayingIsLoadingThenFailed() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 1, at: 101)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, at: 102.4), .playing, "a hiccup is not a stall")
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, at: 102.5), .loading)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, at: 115.9), .loading)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, at: 116), .failed(.noProgress))
        // It recovers if the clock moves before the limit.
        var recovering = SharedMarginPlaybackHealth(startedAt: 100)
        recovering.observe(playerFailed: false, clockSeconds: 1, at: 101)
        XCTAssertEqual(recovering.observe(playerFailed: false, clockSeconds: 1, at: 105), .loading)
        XCTAssertEqual(recovering.observe(playerFailed: false, clockSeconds: 1.3, at: 105.2), .playing)
    }

    func testFailureIsFinalForTheAttempt() {
        var health = health()
        health.observe(playerFailed: true, clockSeconds: nil, at: 100.2)
        // A later reading that looks healthy cannot clear it; Retry makes a new attempt.
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 3, at: 100.4), .failed(.unreadable))
        health.setUserPaused(true, at: 101)
        XCTAssertEqual(health.phase, .failed(.unreadable))
        health.setUserPaused(false, at: 102)
        XCTAssertEqual(health.phase, .failed(.unreadable), "pause then resume of a failed item is not Playing")
        XCTAssertFalse(health.showsPause)
    }

    func testPausingShowsPausedAndTimeSpentPausedNeverFails() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 2, at: 102)
        health.setUserPaused(true, at: 102.1)
        XCTAssertEqual(health.phase, .paused)
        XCTAssertFalse(health.showsPause)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 2, at: 400), .paused)
        health.setUserPaused(false, at: 400)
        XCTAssertEqual(health.phase, .playing, "it had played, so a resume is trusted until the stall limit")
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 2.2, at: 400.2), .playing)
    }

    func testPausingWhileStillLoadingAndResumingStartsTheTimeoutAfresh() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 0, at: 105)
        health.setUserPaused(true, at: 105)
        health.observe(playerFailed: false, clockSeconds: 0, at: 300)
        health.setUserPaused(false, at: 300)
        XCTAssertEqual(health.phase, .loading, "never confirmed, so a resume is not Playing")
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, at: 305), .loading)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, at: 310), .failed(.noProgress))
    }

    func testAFailureWhilePausedIsStillReported() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 1, at: 101)
        health.setUserPaused(true, at: 101.5)
        XCTAssertEqual(health.observe(playerFailed: true, clockSeconds: 1, at: 102), .failed(.unreadable))
    }

    func testReadingsWithNoClockNeverCountAsAdvancing() {
        // Table of neighbouring inputs: a failed item's currentTime is NaN; nothing here may start playing.
        for clock in [nil, Double.nan, .infinity, -.infinity, -3, 0, 0.005] {
            var health = health()
            XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: clock, at: 101), .loading, "\(String(describing: clock))")
            XCTAssertFalse(health.hasPlayed, "\(String(describing: clock))")
        }
    }

    func testAClockThatGoesBackwardsDoesNotCountAsProgress() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 5, at: 101)
        // A seek or restart to an earlier time is not new sound; the stall clock keeps running.
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, at: 103), .loading)
    }

    func testRepeatedPauseAndResumeCallsAreHarmless() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 1, at: 101)
        health.setUserPaused(true, at: 102)
        health.setUserPaused(true, at: 200)
        health.setUserPaused(false, at: 300)
        health.setUserPaused(false, at: 400) // already resumed: must not move the stall clock
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, at: 300.1), .playing)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1.2, at: 400.1), .playing)
    }

    func testASystemPauseAfterPlayingIsPausedNotAFailure() {
        // Mixing mode: a call, Siri or unplugged headphones stop the player and nothing calls setUserPaused.
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 1, at: 101)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, playerAtRest: true, at: 102), .paused)
        XCTAssertFalse(health.showsPause)
        // Far past the stall limit it is still Paused, never failed.
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, playerAtRest: true, at: 500), .paused)
        // It resumes where it stopped, with the stall clock started afresh.
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1, playerAtRest: false, at: 500.1), .playing)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1.2, playerAtRest: false, at: 500.3), .playing)
    }

    func testPlayingAfterASystemPauseShowsPlayingAtOnce() {
        // The listener taps Play on a card the system paused: the card must follow the tap, not the next poll.
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 1, at: 101)
        health.observe(playerFailed: false, clockSeconds: 1, playerAtRest: true, at: 102)
        health.setUserPaused(false, at: 200)
        XCTAssertEqual(health.phase, .playing)
        XCTAssertTrue(health.showsPause)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 1.2, playerAtRest: false, at: 200.2), .playing)
    }

    func testAPlayerAtRestBeforeItEverSoundedStillTimesOut() {
        // Before the first sound a resting player is indistinguishable from one that never started.
        var health = health()
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, playerAtRest: true, at: 105), .loading)
        XCTAssertEqual(health.observe(playerFailed: false, clockSeconds: 0, playerAtRest: true, at: 110), .failed(.noProgress))
    }

    func testAFailureWhileTheSystemHasItPausedIsStillReported() {
        var health = health()
        health.observe(playerFailed: false, clockSeconds: 1, at: 101)
        XCTAssertEqual(health.observe(playerFailed: true, clockSeconds: 1, playerAtRest: true, at: 102), .failed(.unreadable))
    }

    func testEachAttemptHasItsOwnIdentity() {
        // The model drops a reading whose attempt is not the current one, so a late callback from a
        // replaced or retried Margin cannot clear or mark the new one.
        let first = health()
        let retry = health()
        XCTAssertNotEqual(first.attemptID, retry.attemptID)
        XCTAssertEqual(retry.phase, .loading, "a retry starts over rather than inheriting the failure")
    }
}
