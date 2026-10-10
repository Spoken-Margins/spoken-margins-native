import Foundation
import XCTest
@testable import SessionKit

final class SleepTimerPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private var chapters: [MediaTimelineChapter] {
        [("b", 1_000), ("a", 0), ("c", 2_000)].map {
            MediaTimelineChapter(id: $0.0, title: $0.0, startMs: $0.1, transcriptSegmentId: $0.0)
        }
    }

    func testMinuteDeadlines() {
        for (mode, minutes): (SleepTimerMode, Int) in [(.minutes15, 15), (.minutes30, 30), (.minutes45, 45), (.minutes60, 60)] {
            XCTAssertEqual(SleepTimerPolicy.arm(mode, now: now, chapters: [], currentMediaTimeMs: nil),
                           .armed(mode: mode, deadline: now.addingTimeInterval(Double(minutes * 60)), chapterId: nil))
        }
    }

    func testExtendArmedUsesLaterOfDeadlineAndNow() {
        for offset: Double in [-100, 0, 100] {
            let state = SleepTimerState.armed(mode: .minutes60, deadline: now.addingTimeInterval(offset), chapterId: "old")
            XCTAssertEqual(SleepTimerPolicy.extend(state, now: now),
                           .armed(mode: .minutes15, deadline: now.addingTimeInterval(max(offset, 0) + 900), chapterId: nil))
        }
    }

    func testExtendOtherStatesStartsFifteenMinutes() {
        for state: SleepTimerState in [.inactive, .expiryDeferred(mode: .minutes30), .armed(mode: .endOfChapter, deadline: nil, chapterId: "a")] {
            XCTAssertEqual(SleepTimerPolicy.extend(state, now: now),
                           .armed(mode: .minutes15, deadline: now.addingTimeInterval(900), chapterId: nil))
        }
    }

    func testRemainingSecondsCeilClampAndExpiryAtZero() {
        for (offset, expected): (Double, Int) in [(60.01, 61), (60, 60), (0.01, 1), (0, 0), (-1.5, 0)] {
            var state = SleepTimerState.armed(mode: .minutes45, deadline: now.addingTimeInterval(offset), chapterId: nil)
            var remaining: Int? = 999
            let expiry = SleepTimerPolicy.reconcile(state: &state, remainingSeconds: &remaining, now: now,
                                                   isRecording: false, currentMediaTimeMs: nil, chapters: [])
            XCTAssertEqual(remaining, expected)
            XCTAssertEqual(expiry, expected == 0 ? .minutes45 : nil)
        }
        var state = SleepTimerState.inactive
        var remaining: Int? = 999
        XCTAssertNil(SleepTimerPolicy.reconcile(state: &state, remainingSeconds: &remaining, now: now,
                                                isRecording: false, currentMediaTimeMs: nil, chapters: []))
        XCTAssertNil(remaining)
    }

    func testExpiryDefersUntilRecordingEnds() {
        for mode: SleepTimerMode in [.minutes15, .endOfChapter] {
            var state = SleepTimerState.armed(mode: mode, deadline: mode == .endOfChapter ? nil : now, chapterId: "a")
            var remaining: Int?
            XCTAssertNil(SleepTimerPolicy.reconcile(state: &state, remainingSeconds: &remaining, now: now,
                                                    isRecording: true, currentMediaTimeMs: 1_000, chapters: chapters))
            XCTAssertEqual(state, .expiryDeferred(mode: mode))
            XCTAssertNil(SleepTimerPolicy.reconcile(state: &state, remainingSeconds: &remaining, now: now,
                                                    isRecording: true, currentMediaTimeMs: 1_000, chapters: chapters))
            XCTAssertEqual(remaining, 0)
            XCTAssertEqual(SleepTimerPolicy.reconcile(state: &state, remainingSeconds: &remaining, now: now,
                                                      isRecording: false, currentMediaTimeMs: 1_000, chapters: chapters), mode)
        }
    }

    func testChapterEligibilityAndPinnedTarget() {
        XCTAssertNil(SleepTimerPolicy.endOfChapterTarget(chapters: [], currentMediaTimeMs: nil))
        XCTAssertNil(SleepTimerPolicy.endOfChapterTarget(chapters: [chapters[1]], currentMediaTimeMs: 0))
        XCTAssertNil(SleepTimerPolicy.endOfChapterTarget(chapters: chapters, currentMediaTimeMs: 2_000))
        XCTAssertNil(SleepTimerPolicy.arm(.endOfChapter, now: now, chapters: [], currentMediaTimeMs: nil))
        XCTAssertEqual(SleepTimerPolicy.arm(.endOfChapter, now: now, chapters: chapters, currentMediaTimeMs: 1_000),
                       .armed(mode: .endOfChapter, deadline: nil, chapterId: "b"))
        for playhead: Int? in [nil, -1, 0, 999] {
            XCTAssertEqual(SleepTimerPolicy.endOfChapterTarget(chapters: chapters, currentMediaTimeMs: playhead)?.chapterId, "a")
        }
        XCTAssertEqual(SleepTimerPolicy.endOfChapterTarget(chapters: chapters, currentMediaTimeMs: 2_500, chapterId: "a")?.endMs, 1_000)
        XCTAssertEqual(SleepTimerPolicy.endOfChapterTarget(chapters: chapters, currentMediaTimeMs: 1_500, chapterId: "missing")?.chapterId, "b")
        for (playhead, expires) in [(999, false), (1_000, true), (2_500, true)] {
            var state = SleepTimerState.armed(mode: .endOfChapter, deadline: nil, chapterId: "a")
            var remaining: Int? = 123
            XCTAssertEqual(SleepTimerPolicy.reconcile(state: &state, remainingSeconds: &remaining, now: now,
                                                      isRecording: false, currentMediaTimeMs: playhead, chapters: chapters),
                           expires ? .endOfChapter : nil)
            XCTAssertEqual(remaining, 123)
        }
    }

    func testDescriptionsConfirmationsAndActiveStates() {
        XCTAssertFalse(SleepTimerPolicy.isActive(.inactive))
        XCTAssertEqual(SleepTimerPolicy.description(state: .inactive, remainingSeconds: nil), "Sleep Timer")
        XCTAssertEqual(SleepTimerPolicy.description(state: .expiryDeferred(mode: .minutes15), remainingSeconds: 0), "Pauses after recording")
        XCTAssertTrue(SleepTimerPolicy.isActive(.expiryDeferred(mode: .minutes15)))
        for mode: SleepTimerMode in [.minutes15, .minutes30, .minutes45, .minutes60, .endOfChapter] {
            let state = SleepTimerState.armed(mode: mode, deadline: nil, chapterId: nil)
            XCTAssertTrue(SleepTimerPolicy.isActive(state))
            XCTAssertEqual(SleepTimerPolicy.description(state: state, remainingSeconds: nil), mode == .endOfChapter ? "End of Chapter" : "Sleep Timer")
            for (seconds, text) in [(0, "0:00"), (9, "0:09"), (65, "1:05"), (3600, "60:00")] {
                XCTAssertEqual(SleepTimerPolicy.description(state: state, remainingSeconds: seconds), mode == .endOfChapter ? "End of Chapter" : text)
            }
            XCTAssertEqual(SleepTimerPolicy.expiryConfirmation(mode: mode), mode == .endOfChapter ? "Paused at the end of the chapter." : "Sleep timer paused playback.")
        }
    }
}
