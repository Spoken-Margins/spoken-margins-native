import Foundation
import XCTest
@testable import SessionKit

/// #1979: the sleep timer warns at T-60 s, fades over its last 10 s, and then ends.
final class SleepTimerPhaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func phase(secondsLeft: Double, mode: SleepTimerMode = .minutes15) -> SleepTimerPhase {
        SleepTimerPolicy.phase(
            state: .armed(mode: mode, deadline: now.addingTimeInterval(secondsLeft), chapterId: nil),
            now: now, currentMediaTimeMs: nil, chapters: [])
    }

    func testThePhaseFollowsTheTimeLeft() {
        let table: [(left: Double, expected: SleepTimerPhase, note: String)] = [
            (900, .running, "a fresh timer"),
            (61, .running, "just over a minute"),
            (60, .warning(secondsLeft: 60), "exactly a minute: the warning starts"),
            (59.2, .warning(secondsLeft: 60), "seconds round up, as the countdown shows them"),
            (30, .warning(secondsLeft: 30), "mid warning"),
            (10.5, .warning(secondsLeft: 11), "just before the fade"),
            (10, .fading(volumeFactor: 1), "the fade starts at full volume"),
            (5, .fading(volumeFactor: 0.5), "half way down"),
            (0.5, .fading(volumeFactor: 0.05), "nearly silent"),
            (0, .ended, "time is up"),
            (-3, .ended, "a late tick"),
        ]
        for row in table {
            XCTAssertEqual(phase(secondsLeft: row.left), row.expected, row.note)
        }
    }

    func testOtherStates() {
        XCTAssertEqual(SleepTimerPolicy.phase(state: .inactive, now: now, currentMediaTimeMs: nil, chapters: []), .inactive)
        XCTAssertEqual(SleepTimerPolicy.phase(state: .expiryDeferred(mode: .minutes15), now: now, currentMediaTimeMs: nil, chapters: []), .ended)
    }

    func testEndOfChapterCountsDownTheMediaTimeLeft() {
        let chapters = [
            MediaTimelineChapter(id: "a", title: "A", startMs: 0, transcriptSegmentId: "s1"),
            MediaTimelineChapter(id: "b", title: "B", startMs: 600_000, transcriptSegmentId: "s2"),
        ]
        func phase(at ms: Int, chapterId: String? = "a") -> SleepTimerPhase {
            SleepTimerPolicy.phase(
                state: .armed(mode: .endOfChapter, deadline: nil, chapterId: chapterId),
                now: now, currentMediaTimeMs: ms, chapters: chapters)
        }
        XCTAssertEqual(phase(at: 100_000), .running)
        XCTAssertEqual(phase(at: 560_000), .warning(secondsLeft: 40))
        XCTAssertEqual(phase(at: 595_000), .fading(volumeFactor: 0.5))
        XCTAssertEqual(phase(at: 600_000), .ended)
        // The last chapter has no end to count to, and an unknown chapter id falls back to where playback is.
        XCTAssertEqual(phase(at: 700_000, chapterId: "b"), .running)
        XCTAssertEqual(phase(at: 100_000, chapterId: "gone"), .running)
    }

    // MARK: Effects

    func testTheCueIsPlayedOnceAndTheFadeFollowsTheVolume() {
        var tracker = SleepTimerFadeTracker()
        XCTAssertEqual(tracker.apply(.running), [])
        XCTAssertEqual(tracker.apply(.warning(secondsLeft: 60)), [.playWarningCue])
        XCTAssertEqual(tracker.apply(.warning(secondsLeft: 59)), [], "the cue plays once")
        XCTAssertFalse(tracker.isFading)
        XCTAssertEqual(tracker.apply(.fading(volumeFactor: 0.8)), [.setVolumeFactor(0.8)])
        XCTAssertTrue(tracker.isFading)
        XCTAssertEqual(tracker.apply(.fading(volumeFactor: 0.4)), [.setVolumeFactor(0.4)])
        XCTAssertEqual(tracker.apply(.ended), [], "the app restores the volume after it pauses")
        XCTAssertEqual(tracker.reset(), [.restoreVolume])
        XCTAssertEqual(tracker.reset(), [], "nothing left to restore")
    }

    func testExtendingDuringTheWarningOrTheFadeBringsTheVolumeBackAndWarnsAgain() {
        var tracker = SleepTimerFadeTracker()
        _ = tracker.apply(.warning(secondsLeft: 20))
        XCTAssertEqual(tracker.apply(.running), [], "extended during the warning: no volume to restore")
        XCTAssertEqual(tracker.apply(.warning(secondsLeft: 60)), [.playWarningCue], "the next minute warns again")

        _ = tracker.apply(.fading(volumeFactor: 0.3))
        XCTAssertEqual(tracker.apply(.running), [.restoreVolume], "extended mid-fade")
        XCTAssertEqual(tracker.apply(.running), [])
        XCTAssertEqual(tracker.apply(.warning(secondsLeft: 60)), [.playWarningCue])
    }

    func testATickThatFirstSeesTheFadeSkipsTheCue() {
        var tracker = SleepTimerFadeTracker()
        XCTAssertEqual(tracker.apply(.running), [])
        XCTAssertEqual(tracker.apply(.fading(volumeFactor: 0.9)), [.setVolumeFactor(0.9)])
        XCTAssertEqual(tracker.apply(.fading(volumeFactor: 2)), [.setVolumeFactor(1)], "the factor stays in range")
    }

    func testCancellingMidWarningForgetsTheCue() {
        var tracker = SleepTimerFadeTracker()
        _ = tracker.apply(.warning(secondsLeft: 30))
        XCTAssertEqual(tracker.reset(), [])
        XCTAssertEqual(tracker.apply(.warning(secondsLeft: 60)), [.playWarningCue], "a new timer warns again")
    }
}
