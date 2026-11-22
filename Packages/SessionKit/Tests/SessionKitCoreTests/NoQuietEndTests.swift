import Foundation
import SessionKit
import XCTest

/// #3940, Done when 2 and the owner's 2026-11-10 rule (#3650): "I never want a margin to end after silence." A Margin
/// ends hands-free only on the spoken phrase, so no stretch of quiet, however long, may give an end. These drive the
/// phrase rule with a fake audio clock and fail if anything in it ends a Margin without the phrase. The app side of
/// the guard (no timer wired near the end path) lands with the listener's own tests.
final class NoQuietEndTests: XCTestCase {
    private func assertNeverEnds(_ outcome: MarginEndPhrase.Outcome, at clock: Int, file: StaticString = #filePath, line: UInt = #line) {
        if case .end = outcome { XCTFail("Ended with no phrase at \(clock) ms", file: file, line: line) }
        if case .confirming = outcome { XCTFail("Confirming with no phrase at \(clock) ms", file: file, line: line) }
    }

    func testTenMinutesOfNothingNeverEnds() {
        var window = MarginEndPhraseWindow()
        var clock = 0
        while clock <= 10 * 60_000 {
            assertNeverEnds(window.advance(audioNowMs: clock), at: clock)
            clock += 250
        }
    }

    func testASentenceThenNinetySecondsOfQuietThenAnotherNeverEnds() {
        var window = MarginEndPhraseWindow()
        let first = ["that", "is", "my", "first", "thought"].enumerated().map {
            MarginEndPhraseWord(text: $0.element, startMs: 2_000 + $0.offset * 400, endMs: 2_300 + $0.offset * 400)
        }
        assertNeverEnds(window.advance(audioNowMs: 4_300, hearing: first), at: 4_300)
        var clock = 4_300
        while clock < 94_300 {
            clock += 500
            assertNeverEnds(window.advance(audioNowMs: clock), at: clock)
        }
        let second = MarginEndPhraseWord(text: "and", startMs: 95_000, endMs: 95_300)
        assertNeverEnds(window.advance(audioNowMs: 95_300, hearing: [second]), at: 95_300)
        for clock in stride(from: 95_300, through: 130_000, by: 500) {
            assertNeverEnds(window.advance(audioNowMs: clock), at: clock)
        }
    }

    func testAPhraseWordsAloneNeverEndsEvenWithAVeryLongPauseBetween() {
        // Quiet between "stop" and "margin" is not the phrase, however long: the two words must be close together.
        var window = MarginEndPhraseWindow()
        _ = window.advance(audioNowMs: 5_300, hearing: [MarginEndPhraseWord(text: "stop", startMs: 5_000, endMs: 5_300)])
        for clock in stride(from: 5_300, through: 70_000, by: 500) {
            assertNeverEnds(window.advance(audioNowMs: clock), at: clock)
        }
        let late = MarginEndPhraseWord(text: "margin", startMs: 70_000, endMs: 70_400)
        assertNeverEnds(window.advance(audioNowMs: 70_400, hearing: [late]), at: 70_400)
        assertNeverEnds(window.advance(audioNowMs: 72_000), at: 72_000)
    }

    func testEveryConstantInTheRuleIsAShortWindowNotATimeout() {
        // The only clock the rule reads is the audio clock, and only to confirm a phrase already heard: with no
        // words at all there is nothing it can end, at any clock value.
        for clock in [0, 1, 999, 1_000, 300_000, Int.max / 2] {
            XCTAssertEqual(MarginEndPhrase.evaluate(words: [], audioNowMs: clock), .none)
        }
    }
}
