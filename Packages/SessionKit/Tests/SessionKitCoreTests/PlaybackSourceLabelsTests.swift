import Foundation
import XCTest
@testable import SessionKit

final class PlaybackSourceLabelsTests: XCTestCase {
    func testChapterRowUsesSourceWhenThereIsNoChapter() {
        for chapter: String? in [nil, "", " \n\t", "\u{00a0}"] {
            XCTAssertEqual(PlaybackSourceLabels.chapterTitle(chapter, sourceTitle: "  The source  "), "The source")
        }
        XCTAssertEqual(PlaybackSourceLabels.chapterTitle("Chapter two", sourceTitle: "The source"), "Chapter two")
        XCTAssertEqual(PlaybackSourceLabels.chapterTitle("  Chapter two\n", sourceTitle: "The source"), "Chapter two")
        XCTAssertEqual(PlaybackSourceLabels.chapterTitle(nil, sourceTitle: " \n"), "Current source")
    }

    func testChapterLabelsPreserveWordsPunctuationAndUnicode() {
        for title in ["Case Matters", "Wait—why?", "Cafe\u{0301} ☕", String(repeating: "A", count: 4_000)] {
            XCTAssertEqual(PlaybackSourceLabels.chapterTitle(title, sourceTitle: "Other"), title)
            XCTAssertEqual(PlaybackSourceLabels.chapterTitle(nil, sourceTitle: title), title)
        }
    }

    func testSleepTagIsAbsentOnlyWhenInactive() {
        XCTAssertNil(PlaybackSourceLabels.sleepTag(state: .inactive, remainingSeconds: 700))
        XCTAssertEqual(PlaybackSourceLabels.sleepTag(state: .armed(mode: .minutes15, deadline: nil, chapterId: nil), remainingSeconds: nil), "Sleep timer on")
        XCTAssertEqual(PlaybackSourceLabels.sleepTag(state: .armed(mode: .endOfChapter, deadline: nil, chapterId: "chapter"), remainingSeconds: 700), "Sleep at chapter end")
        XCTAssertEqual(PlaybackSourceLabels.sleepTag(state: .expiryDeferred(mode: .minutes15), remainingSeconds: 0), "Sleep after recording")
    }

    func testSleepMinutesRoundUpWithoutShowingZeroOrOverflowing() {
        let armed = SleepTimerState.armed(mode: .minutes15, deadline: nil, chapterId: nil)
        for (seconds, text) in [(-1, "Sleep 1m"), (0, "Sleep 1m"), (1, "Sleep 1m"), (59, "Sleep 1m"), (60, "Sleep 1m"), (61, "Sleep 2m"), (720, "Sleep 12m"), (721, "Sleep 13m")] {
            XCTAssertEqual(PlaybackSourceLabels.sleepTag(state: armed, remainingSeconds: seconds), text)
        }
        XCTAssertEqual(PlaybackSourceLabels.sleepTag(state: armed, remainingSeconds: Int.max), "Sleep \(Int.max / 60 + 1)m")
    }

    func testPreparedAudioIsLabelledForTextSourcesOnly() {
        for (fraction, label): (Double, String) in [(0, "Prepared audio: 0%"), (0.659, "Prepared audio: 65%"), (0.999, "Prepared audio: 99%"), (1, "Prepared audio: 100%"), (-0.5, "Prepared audio: 0%"), (2, "Prepared audio: 100%")] {
            XCTAssertEqual(PlaybackSourceLabels.preparedAudio(fraction: fraction, isNativeAudio: false), label)
            XCTAssertNil(PlaybackSourceLabels.preparedAudio(fraction: fraction, isNativeAudio: true))
        }
    }

    func testUnknownOrInvalidPreparationHasNoInventedPercentage() {
        for fraction: Double? in [nil, .nan, .infinity, -.infinity] {
            XCTAssertNil(PlaybackSourceLabels.preparedAudio(fraction: fraction, isNativeAudio: false))
        }
    }
}
