import Foundation
import SessionKit
import XCTest

/// #3940, PR 1 of the Design: the rule for ending a Margin by voice. One row per rule and variant in the issue's
/// "table of neighbouring inputs" (case, punctuation, quotes, Unicode form, a pause before or after, lookalikes),
/// plus the recogniser spellings the owner saw on his phone (2026-11-17): "end martian", "stop martian" and
/// "and martian". A wrong "end" cuts the listener's Margin short, so every row that must not end one has a test.
final class MarginEndPhraseTests: XCTestCase {
    /// Words said one after the other: `wordMs` long, `gapMs` apart, the first starting at `start`. Returns them and
    /// where the last one ends.
    private func say(_ text: String, at start: Int, wordMs: Int = 300, gapMs: Int = 100) -> (words: [MarginEndPhraseWord], endMs: Int) {
        var words: [MarginEndPhraseWord] = []
        var clock = start
        for piece in text.split(separator: " ") {
            words.append(MarginEndPhraseWord(text: String(piece), startMs: clock, endMs: clock + wordMs))
            clock += wordMs + gapMs
        }
        return (words, (words.last?.endMs) ?? start)
    }

    /// What the rule says once the audio clock is `afterMs` past the last word.
    private func outcome(_ text: String, at start: Int = 5_000, afterMs: Int = MarginEndPhrase.confirmMs) -> MarginEndPhrase.Outcome {
        let said = say(text, at: start)
        return MarginEndPhrase.evaluate(words: said.words, audioNowMs: said.endMs + afterMs)
    }

    private func assertEnds(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .end = outcome(text) else {
            return XCTFail("\"\(text)\" should end the Margin, got \(outcome(text))", file: file, line: line)
        }
    }

    private func assertDoesNotEnd(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome(text), .none, "\"\(text)\" must not end the Margin", file: file, line: line)
    }

    // MARK: The phrases, and how they may be written

    func testBothPhrasesEndAMargin() {
        assertEnds("that is my point stop margin")
        assertEnds("that is my point end margin")
        assertEnds("stop margin")
    }

    func testCasePunctuationAndQuotesDoNotMatter() {
        assertEnds("point. Stop Margin.")
        assertEnds("point STOP MARGIN")
        assertEnds("point stop, margin")
        assertEnds("point \u{201C}stop margin\u{201D}")
        assertEnds("point 'stop margin'")
        assertEnds("point \u{2018}stop margin\u{2019}")
        assertEnds("point stop... margin!")
        assertEnds("point (end margin)")
    }

    func testAWordWrittenAsTwoOrJoinedByAHyphenStillCounts() {
        let oneWord = [MarginEndPhraseWord(text: "point", startMs: 5_000, endMs: 5_300),
                       MarginEndPhraseWord(text: "Stop margin.", startMs: 5_400, endMs: 6_000)]
        XCTAssertEqual(MarginEndPhrase.evaluate(words: oneWord, audioNowMs: 7_000), .end(cutAtMs: 5_250))
        let hyphen = [MarginEndPhraseWord(text: "point", startMs: 5_000, endMs: 5_300),
                      MarginEndPhraseWord(text: "stop-margin", startMs: 5_400, endMs: 6_000)]
        XCTAssertEqual(MarginEndPhrase.evaluate(words: hyphen, audioNowMs: 7_000), .end(cutAtMs: 5_250))
    }

    func testAThePeopleAddBetweenIsAccepted() {
        assertEnds("point stop the margin")
        assertEnds("point end the margin")
        assertEnds("point Stop the Margin.")
    }

    // MARK: The recogniser's spellings (owner, 2026-11-17)

    func testMartianSpellingsEnd() {
        assertEnds("point stop martian")
        assertEnds("point end martian")
        assertEnds("point. End Martian.")
    }

    func testAndMartianEndsOnlyAfterAPause() {
        // "and" starts so many sentences: it needs a 0.4 s pause before it, on top of being the last words.
        let heard = say("that is my point", at: 5_000)
        let afterPause = say("and martian", at: heard.endMs + 600)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: heard.words + afterPause.words, audioNowMs: afterPause.endMs + 1_000),
                       .end(cutAtMs: heard.endMs + 450))
        let runOn = say("and martian", at: heard.endMs + 200)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: heard.words + runOn.words, audioNowMs: runOn.endMs + 1_000), .none,
                       "Run on from the last word, it is just a sentence")
        assertDoesNotEnd("this and martian")
    }

    func testMartianLookalikesDoNotEnd() {
        assertDoesNotEnd("point and martian music")
        assertDoesNotEnd("point a martian")
        assertDoesNotEnd("point stop martians")
        assertDoesNotEnd("point end martians")
        assertDoesNotEnd("point stop the martian")
        assertDoesNotEnd("point the martian")
        assertDoesNotEnd("point martian")
    }

    // MARK: Lookalikes and other sentences

    func testLookalikeWordsDoNotEnd() {
        assertDoesNotEnd("point stop margins")
        assertDoesNotEnd("point stop marginal")
        assertDoesNotEnd("point stopped margin")
        assertDoesNotEnd("point stops margin")
        assertDoesNotEnd("point end margins")
        assertDoesNotEnd("point ended margin")
        assertDoesNotEnd("point ending margin")
        assertDoesNotEnd("point stop margin's")
        assertDoesNotEnd("point stopmargin")
        assertDoesNotEnd("point stop")
        assertDoesNotEnd("point margin")
        assertDoesNotEnd("point and margin")
        assertDoesNotEnd("point and the margin")
        assertDoesNotEnd("point do not stop the the margin")
    }

    func testAnAccentedLookalikeDoesNotEndInEitherUnicodeForm() {
        let composed = "m\u{00E1}rgin"
        let decomposed = "ma\u{0301}rgin"
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars), "Two different spellings of one word")
        for margin in [composed, decomposed] {
            assertDoesNotEnd("point stop \(margin)")
        }
    }

    func testThePhraseInsideALongerSentenceDoesNotEnd() {
        assertDoesNotEnd("I will not stop margin notes here")
        assertDoesNotEnd("I will not stop margin notes")
    }

    func testTheWordsBeforeAndAfterAreWhatDecides() {
        assertEnds("I will not stop margin")
        assertDoesNotEnd("stop margin is how it ends")
        assertDoesNotEnd("stop margin notes")
        assertDoesNotEnd("point stop margin now")
    }

    func testTheTwoWordsMustBeCloseTogether() {
        let tight = [MarginEndPhraseWord(text: "stop", startMs: 5_000, endMs: 5_300),
                     MarginEndPhraseWord(text: "margin", startMs: 6_100, endMs: 6_400)] // 800 ms apart: allowed
        XCTAssertEqual(MarginEndPhrase.evaluate(words: tight, audioNowMs: 7_400), .end(cutAtMs: 4_850))
        let apart = [MarginEndPhraseWord(text: "stop", startMs: 5_000, endMs: 5_300),
                     MarginEndPhraseWord(text: "margin", startMs: 6_101, endMs: 6_401)] // 801 ms: not
        XCTAssertEqual(MarginEndPhrase.evaluate(words: apart, audioNowMs: 7_401), .none)
        let withThe = [MarginEndPhraseWord(text: "stop", startMs: 5_000, endMs: 5_300),
                       MarginEndPhraseWord(text: "the", startMs: 5_400, endMs: 5_500),
                       MarginEndPhraseWord(text: "margin", startMs: 6_400, endMs: 6_700)] // "the" to "margin" 900 ms
        XCTAssertEqual(MarginEndPhrase.evaluate(words: withThe, audioNowMs: 7_700), .none)
    }

    // MARK: The confirming second

    func testNothingEndsUntilAFullSecondAfterThePhrase() {
        let said = say("that is my point stop margin", at: 5_000)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words, audioNowMs: said.endMs),
                       .confirming(phraseStartMs: said.words[4].startMs))
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words, audioNowMs: said.endMs + 999),
                       .confirming(phraseStartMs: said.words[4].startMs))
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words, audioNowMs: said.endMs + 1_000),
                       .end(cutAtMs: said.words[4].startMs - 150))
    }

    func testAWordWithinTheSecondCancelsIt() {
        let said = say("that is my point stop margin", at: 5_000)
        let more = MarginEndPhraseWord(text: "notes", startMs: said.endMs + 500, endMs: said.endMs + 800)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words + [more], audioNowMs: said.endMs + 1_000), .none)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words + [more], audioNowMs: said.endMs + 5_000), .none)
    }

    func testBackgroundWordsInTheSecondCancelIt() {
        let said = say("that is my point stop margin", at: 5_000)
        let passenger = MarginEndPhraseWord(text: "okay", startMs: said.endMs + 200, endMs: said.endMs + 400)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words + [passenger], audioNowMs: said.endMs + 2_000), .none,
                       "Said again after it, the listener ends it again")
    }

    // MARK: Too early, said twice, the cut

    func testAPhraseInTheFirstSecondIsIgnored() {
        XCTAssertEqual(outcome("stop margin", at: 0), .none)
        XCTAssertEqual(outcome("stop margin", at: 999), .none)
        XCTAssertEqual(outcome("stop margin", at: 1_000), .end(cutAtMs: 850))
    }

    func testTheCutIsJustBeforeThePhraseAndNeverBeforeZero() {
        // "point" 5000 to 5300, "stop" starts at 5400: the cut is 150 ms before it.
        XCTAssertEqual(outcome("point stop margin", at: 5_000), .end(cutAtMs: 5_250))
        XCTAssertEqual(MarginEndPhrase.trailingPhrase(in: say("stop margin", at: 100).words)?.cutAtMs, 0)
    }

    func testAPhraseSaidTwiceQuicklyIsOneEndAndTheCutTakesBoth() {
        let said = say("that is my point stop margin stop margin", at: 5_000)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: said.words, audioNowMs: said.endMs + 1_000),
                       .end(cutAtMs: said.words[4].startMs - 150))
        XCTAssertEqual(MarginEndPhrase.trailingPhrase(in: said.words)?.firstWordIndex, 4)
    }

    func testAnEarlierPhraseFarBeforeIsNotPartOfTheCut() {
        let first = say("point stop margin", at: 5_000)
        let later = say("stop margin", at: first.endMs + 3_000)
        let words = first.words + later.words
        let match = MarginEndPhrase.trailingPhrase(in: words)
        XCTAssertEqual(match?.firstWordIndex, 3, "Only the later phrase: the earlier one was three seconds before")
        XCTAssertEqual(match?.endMs, later.endMs)
    }

    func testAPhraseHeardMidSentenceThenMoreWordsThenAnotherEndsOnTheLastOne() {
        let first = say("I might stop margin", at: 5_000)
        let rest = say("notes are long", at: first.endMs + 300)
        let last = say("stop margin", at: rest.endMs + 2_000)
        let words = first.words + rest.words + last.words
        XCTAssertEqual(MarginEndPhrase.evaluate(words: first.words + rest.words, audioNowMs: rest.endMs + 5_000), .none)
        XCTAssertEqual(MarginEndPhrase.evaluate(words: words, audioNowMs: last.endMs + 1_000), .end(cutAtMs: last.words[0].startMs - 150))
    }

    // MARK: The saved file's words (the cut)

    func testTheSavedFilesTrailingPhraseNeedsNoConfirmingSecond() {
        let said = say("that is my point stop margin", at: 0)
        let match = MarginEndPhrase.trailingPhrase(in: said.words)
        XCTAssertEqual(match?.firstWordIndex, 4)
        XCTAssertEqual(match?.startMs, said.words[4].startMs)
        XCTAssertEqual(match?.endMs, said.endMs)
        XCTAssertEqual(match?.cutAtMs, said.words[4].startMs - 150)
    }

    func testTheSavedFilesFinalWordsDisagreeingKeepEverything() {
        XCTAssertNil(MarginEndPhrase.trailingPhrase(in: say("that is my point stop margin notes", at: 0).words))
        XCTAssertNil(MarginEndPhrase.trailingPhrase(in: say("that is my point", at: 0).words))
        XCTAssertNil(MarginEndPhrase.trailingPhrase(in: []))
    }

    func testEmptyAndPunctuationOnlyInputGivesNothing() {
        XCTAssertEqual(MarginEndPhrase.evaluate(words: [], audioNowMs: 60_000), .none)
        let marks = [MarginEndPhraseWord(text: ".", startMs: 5_000, endMs: 5_100), MarginEndPhraseWord(text: "", startMs: 5_200, endMs: 5_300)]
        XCTAssertEqual(MarginEndPhrase.evaluate(words: marks, audioNowMs: 60_000), .none)
    }

    func testAVeryLongSentenceStillEndsOnItsLastWords() {
        let filler = String(repeating: "word ", count: 2_000)
        assertEnds(filler + "stop margin")
        assertDoesNotEnd(filler + "stop margin " + "word")
    }

    // MARK: The window

    func testAVolatileGuessRevisedToLongerWordsNeverEnds() {
        var window = MarginEndPhraseWindow()
        let said = say("that is my point stop margin", at: 5_000)
        XCTAssertEqual(window.advance(audioNowMs: said.endMs + 200, hearing: said.words),
                       .confirming(phraseStartMs: said.words[4].startMs))
        let revised = said.words + [MarginEndPhraseWord(text: "notes", startMs: said.endMs + 300, endMs: said.endMs + 600)]
        XCTAssertEqual(window.advance(audioNowMs: said.endMs + 700, hearing: Array(revised[4...])), .none)
        XCTAssertEqual(window.advance(audioNowMs: said.endMs + 5_000), .none)
    }

    func testAFinalResultReplacesTheGuessItCovers() {
        var window = MarginEndPhraseWindow()
        let guess = say("stop margin", at: 5_000)
        _ = window.advance(audioNowMs: 6_000, hearing: guess.words)
        let final = say("stop marching", at: 5_000)
        XCTAssertEqual(window.advance(audioNowMs: 7_500, hearing: final.words, isFinal: true), .none)
        XCTAssertEqual(window.words.map(\.text), ["stop", "marching"])
    }

    func testAGuessRevisedToNothingRetractsTheOldPhrase() {
        var window = MarginEndPhraseWindow()
        let said = say("that is my point stop margin", at: 5_000)
        XCTAssertEqual(window.advance(audioNowMs: said.endMs, hearing: said.words),
                       .confirming(phraseStartMs: said.words[4].startMs))
        // The recogniser now reads that stretch as nothing: an empty result that starts where the phrase did.
        XCTAssertEqual(window.advance(audioNowMs: said.endMs + 200, resultStartMs: said.words[4].startMs), .none)
        XCTAssertEqual(window.advance(audioNowMs: said.endMs + 1_500), .none, "A retracted phrase is never confirmed")
        // A result of only punctuation retracts it too.
        var other = MarginEndPhraseWindow()
        _ = other.advance(audioNowMs: said.endMs, hearing: said.words)
        let dot = [MarginEndPhraseWord(text: ".", startMs: said.words[4].startMs, endMs: said.words[4].startMs + 100)]
        XCTAssertEqual(other.advance(audioNowMs: said.endMs + 1_500, hearing: dot), .none)
    }

    func testALateFinalForEarlierAudioKeepsTheNewerTail() {
        var window = MarginEndPhraseWindow()
        let earlier = say("that is my point", at: 5_000)       // ends 6500
        let tail = say("stop margin", at: 9_000)               // volatile tail, already heard
        _ = window.advance(audioNowMs: tail.endMs, hearing: tail.words)
        XCTAssertEqual(window.advance(audioNowMs: tail.endMs, hearing: earlier.words, isFinal: true),
                       .confirming(phraseStartMs: 9_000))
        XCTAssertEqual(window.words.map(\.text), ["that", "is", "my", "point", "stop", "margin"])
    }

    func testAnEarlyFirstTryDoesNotMakeTheLaterPhraseTooEarly() {
        let first = say("stop margin", at: 400)               // starts before the first second
        let second = say("stop margin", at: first.endMs + 100)
        let words = first.words + second.words
        XCTAssertEqual(MarginEndPhrase.evaluate(words: words, audioNowMs: second.endMs + 1_000), .end(cutAtMs: 250),
                       "The rule's early check is about the phrase said last; the cut takes both tries")
    }

    func testARunOnAndMartianStaysARunOnAfterTheWordBeforeAgesOut() {
        var window = MarginEndPhraseWindow()
        _ = window.advance(audioNowMs: 6_100, hearing: say("that is it", at: 5_000).words)
        // Results arrive late: the clock is 11 s past that word when "and martian", said right after it, lands.
        let runOn = say("and martian", at: 6_300)
        XCTAssertEqual(window.advance(audioNowMs: 17_100, hearing: runOn.words), .none)
        XCTAssertEqual(window.advance(audioNowMs: 19_000), .none)
    }

    func testTheWindowStaysSmallThroughATwentyMinuteMarginAndStillFindsTheEnd() {
        var window = MarginEndPhraseWindow()
        var clock = 2_000
        var largest = 0
        while clock < 20 * 60_000 {
            let word = MarginEndPhraseWord(text: "talking", startMs: clock, endMs: clock + 400)
            XCTAssertEqual(window.advance(audioNowMs: clock + 400, hearing: [word]), .none)
            largest = max(largest, window.words.count)
            clock += 2_000
        }
        XCTAssertLessThanOrEqual(largest, 7, "Only the last ten seconds of words, and the one before them, are kept")
        let end = say("stop margin", at: clock)
        XCTAssertEqual(window.advance(audioNowMs: end.endMs, hearing: end.words), .confirming(phraseStartMs: clock))
        XCTAssertEqual(window.advance(audioNowMs: end.endMs + 1_000), .end(cutAtMs: clock - 150))
    }

    func testAnAndMartianAfterALongPauseStillCountsOnceTheWordBeforeIsForgotten() {
        var window = MarginEndPhraseWindow()
        _ = window.advance(audioNowMs: 5_500, hearing: say("that is it", at: 5_000).words)
        let said = say("and martian", at: 40_000)
        XCTAssertEqual(window.advance(audioNowMs: said.endMs, hearing: said.words), .confirming(phraseStartMs: 40_000))
        XCTAssertEqual(window.advance(audioNowMs: said.endMs + 1_000), .end(cutAtMs: 39_850))
    }
}
