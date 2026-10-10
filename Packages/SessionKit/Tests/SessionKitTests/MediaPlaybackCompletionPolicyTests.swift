import XCTest
@testable import SessionKitAudio

/// The rule that decides when a podcast episode counts as finished (#643, #588). A wrong answer
/// either marks an episode done after an interruption mid-episode, so Play restarts it from
/// 0:00, or leaves a finished episode open. Every case below pins one input of the rule with the
/// other inputs held at "a system pause 59 s into a 60 s episode, the policy's best case for
/// ending", so a case fails only because of the input it names (#1129, BIG-06; #1133, ANC-07).
final class MediaPlaybackCompletionPolicyTests: XCTestCase {
    private func ended(
        notification: Bool = false,
        targetMatches: Bool = true,
        paused: Bool = true,
        userPaused: Bool = false,
        seekPending: Bool = false,
        at currentMs: Int? = 59_050,
        of durationMs: Int? = 60_000
    ) -> Bool {
        MediaPlaybackCompletionPolicy.reachedEffectiveEnd(
            completionNotificationObserved: notification,
            targetMatches: targetMatches,
            playerIsPaused: paused,
            userRequestedPause: userPaused,
            seekIsPending: seekPending,
            currentMediaTimeMs: currentMs,
            durationMs: durationMs
        )
    }

    func testAPlayerPauseWithinTheLastSecondAndAHalfIsTheEnd() {
        XCTAssertTrue(ended(at: 59_050), "950 ms left")
        XCTAssertTrue(ended(at: 58_501), "1_499 ms left")
        XCTAssertTrue(ended(at: 58_500), "exactly 1_500 ms left is still the end")
        XCTAssertTrue(ended(at: 60_000), "paused on the last frame")
        XCTAssertTrue(ended(at: 61_000), "a clock a little past the length is still the end")
    }

    func testAPlayerPauseFurtherFromTheEndIsNotTheEnd() {
        // An interruption, route change or stall mid-episode is not the end: marking it so
        // finishes the episode and Play then starts it again from 0:00 (#643).
        XCTAssertFalse(ended(at: 58_499), "1_501 ms left is one millisecond too far")
        XCTAssertFalse(ended(at: 58_400), "1_600 ms left")
        XCTAssertFalse(ended(at: 55_000), "5 s left")
        XCTAssertFalse(ended(at: 30_000), "halfway")
        XCTAssertFalse(ended(at: 1), "just started")
        XCTAssertFalse(ended(at: 0), "at the start of a 60 s episode")
    }

    func testAPauseAtZeroIsNeverTheEndEvenOfAVeryShortEpisode() {
        XCTAssertFalse(ended(at: 0, of: 1_000), "a player that has not moved has not finished, however short the clip")
        XCTAssertTrue(ended(at: 1, of: 1_000), "once it has moved, 999 ms left is inside the tolerance")
    }

    func testTheEndNeedsAPausedPlayerOnTheSameTargetWithNoUserIntent() {
        XCTAssertFalse(ended(paused: false), "a player still playing near the end has not stopped")
        XCTAssertFalse(ended(targetMatches: false), "another item's clock says nothing about this one")
        XCTAssertFalse(ended(userPaused: true), "the listener paused")
        XCTAssertFalse(ended(seekPending: true), "a seek is on its way")
    }

    func testTheEndNeedsAKnownPositionAndLength() {
        XCTAssertFalse(ended(at: nil), "no clock")
        XCTAssertFalse(ended(of: nil), "no length")
        XCTAssertFalse(ended(at: 0, of: 0), "a zero length is not a length")
        XCTAssertFalse(ended(at: 59_050, of: 0))
        XCTAssertFalse(ended(at: 59_050, of: -1))
    }

    func testTheEndOfItemNotificationEndsTheEpisodeFromAnywhereButOnlyForItsOwnTarget() {
        XCTAssertTrue(ended(notification: true, paused: false, at: 30_000), "the player said it finished")
        XCTAssertTrue(ended(notification: true, paused: false, at: nil, of: nil), "it needs no clock or length")
        XCTAssertFalse(ended(notification: true, targetMatches: false, paused: false, at: 30_000),
                       "a notification for another item is not this item ending")
        XCTAssertFalse(ended(notification: true, targetMatches: false),
                       "and it does not become the end because the clock is also near the end of another item")
    }

    func testASeekBackFromTheEndLeavesTheEndedState() {
        // #588: a scrub back from the end must clear the end-of-item notification, or the
        // engine moves the episode straight back to its end.
        XCTAssertTrue(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 0, durationMs: 178_808))
        XCTAssertTrue(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 177_000, durationMs: 178_808))
        XCTAssertTrue(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 178_000, durationMs: 178_808),
                      "a place the listener chose inside the end tolerance is not the end")
        XCTAssertTrue(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 178_807, durationMs: 178_808))
        XCTAssertFalse(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 178_808, durationMs: 178_808))
        XCTAssertFalse(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 200_000, durationMs: 178_808),
                       "a destination past the end is the end")
        XCTAssertTrue(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 178_000, durationMs: nil))
        XCTAssertTrue(MediaPlaybackCompletionPolicy.seekLeavesEnd(toMediaTimeMs: 178_000, durationMs: 0))
    }
}
