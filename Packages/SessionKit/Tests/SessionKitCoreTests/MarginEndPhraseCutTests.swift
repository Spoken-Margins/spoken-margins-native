import Foundation
import SessionKit
import XCTest

/// #3940, PR 2: the cut that takes "stop margin" off a saved Margin. A cut that loses the listener's own words is
/// worse than a phrase left in, so every row that is not clearly "the transcript ends with the phrase" keeps all.
final class MarginEndPhraseCutTests: XCTestCase {
    private func words(_ pieces: [String], from start: Int = 0, wordMs: Int = 300, gapMs: Int = 100) -> [MarginEndPhraseWord] {
        pieces.enumerated().map {
            let begin = start + $0.offset * (wordMs + gapMs)
            return MarginEndPhraseWord(text: $0.element, startMs: begin, endMs: begin + wordMs)
        }
    }

    func testThePhraseAtTheEndIsCutFromTheAudioAndTheText() throws {
        let heard = words(["that", "is", "my", "point", "stop", "margin"])
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "That is my point. Stop margin.", words: heard))
        XCTAssertEqual(cut.text, "That is my point.")
        XCTAssertEqual(cut.keptWordCount, 4)
        XCTAssertEqual(cut.cutAtMs, 1_500, "150 ms back would be 1,450, inside \"point\" (ends 1,500): the cut waits for the word to end")
    }

    func testEveryAcceptedSpellingIsCutWithItsOwnText() throws {
        let cases: [(spoken: [String], text: String, kept: String)] = [
            (["so", "stop", "the", "margin"], "So stop the margin", "So"),
            (["so", "end", "margin"], "So, end margin.", "So,"),
            (["so", "end", "martian"], "So. End Martian.", "So."),
            (["so", "stop", "martian"], "so stop martian", "so"),
            (["well", "and", "martian"], "Well. And Martian.", "Well."),
        ]
        for item in cases {
            // "and martian" needs a pause before it: leave one.
            var heard = words(item.spoken)
            if item.spoken[1] == "and" { heard[1].startMs += 500; heard[1].endMs += 500; heard[2].startMs += 500; heard[2].endMs += 500 }
            let cut = MarginEndPhrase.cut(text: item.text, words: heard)
            XCTAssertEqual(cut?.text, item.kept, "\(item.text)")
            XCTAssertEqual(cut?.keptWordCount, 1, "\(item.text)")
        }
    }

    func testAPhraseSaidTwiceIsCutOnce() throws {
        let heard = words(["well", "that", "is", "it", "stop", "margin", "stop", "margin"])
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "Well that is it. Stop margin. Stop margin.", words: heard))
        XCTAssertEqual(cut.text, "Well that is it.")
        XCTAssertEqual(cut.keptWordCount, 4)
    }

    func testPunctuationOnlyWordsAfterThePhraseGoWithIt() throws {
        var heard = words(["that", "is", "it", "stop", "margin"])
        heard.append(MarginEndPhraseWord(text: ".", startMs: 2_000, endMs: 2_050))
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "That is it. Stop margin.", words: heard))
        XCTAssertEqual(cut.keptWordCount, 3)
    }

    func testNothingIsCutWhenTheRecognisersDisagreeOrNothingWouldBeLeft() {
        let heard = words(["that", "is", "my", "point", "stop", "margin"])
        // The full text ends differently from the aligned words: keep everything.
        XCTAssertNil(MarginEndPhrase.cut(text: "That is my point stop marching.", words: heard))
        XCTAssertNil(MarginEndPhrase.cut(text: "Stop margin. That is my point.", words: heard))
        XCTAssertNil(MarginEndPhrase.cut(text: "", words: heard))
        // No phrase at the end.
        XCTAssertNil(MarginEndPhrase.cut(text: "That is my point", words: words(["that", "is", "my", "point"])))
        XCTAssertNil(MarginEndPhrase.cut(text: "Stop margin notes", words: words(["stop", "margin", "notes"])))
        // The whole Margin is the phrase: nothing would be left.
        XCTAssertNil(MarginEndPhrase.cut(text: "Stop margin.", words: words(["stop", "margin"])))
        // Only punctuation before the phrase: nothing would be left.
        let onlyDot = [MarginEndPhraseWord(text: ".", startMs: 0, endMs: 50)] + words(["stop", "margin"], from: 400)
        XCTAssertNil(MarginEndPhrase.cut(text: ". Stop margin", words: onlyDot))
    }

    func testAPhraseSharingAWordWithTheSpeechBeforeItIsKept() {
        // One recognised word holds "point stop margin": it can't be split between kept and cut.
        let heard = words(["that", "is"]) + [MarginEndPhraseWord(text: "point stop margin", startMs: 800, endMs: 1_700)]
        XCTAssertNil(MarginEndPhrase.cut(text: "That is point stop margin", words: heard))
    }

    func testAPhraseWordOnItsOwnAsTheLastRecognisedWordIsCut() throws {
        let heard = words(["that", "is", "it"]) + [MarginEndPhraseWord(text: "Stop margin.", startMs: 1_300, endMs: 1_900)]
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "That is it. Stop margin.", words: heard))
        XCTAssertEqual(cut.text, "That is it.")
        XCTAssertEqual(cut.keptWordCount, 3)
    }

    func testTextWithCurlyApostrophesAndUnicodeKeepsItsOwnWords() throws {
        let heard = words(["it", "s", "caf\u{00E9}", "time", "stop", "margin"])
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "It\u{2019}s caf\u{00E9} time. Stop margin.", words: heard),
                                "'s is its own token on both sides")
        XCTAssertEqual(cut.text, "It\u{2019}s caf\u{00E9} time.")
    }

    func testAShortWordRightBeforeThePhraseIsKeptWhole() throws {
        // The phrase starts 120 ms in and "um" ends at 100: the cut is at 100, so "um" is whole.
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "Um stop margin", words: words(["um", "stop", "margin"], from: 0, wordMs: 100, gapMs: 20)))
        XCTAssertEqual(cut.cutAtMs, 100)
        XCTAssertEqual(cut.text, "Um")
    }

    func testTheCutNeverClipsTheLastKeptWord() throws {
        // The last word touches the phrase: 150 ms back would cut into "it".
        let heard = [
            MarginEndPhraseWord(text: "that", startMs: 0, endMs: 300), MarginEndPhraseWord(text: "is", startMs: 300, endMs: 500),
            MarginEndPhraseWord(text: "it", startMs: 500, endMs: 1_000), MarginEndPhraseWord(text: "stop", startMs: 1_000, endMs: 1_300),
            MarginEndPhraseWord(text: "margin", startMs: 1_300, endMs: 1_800)
        ]
        let cut = try XCTUnwrap(MarginEndPhrase.cut(text: "That is it. Stop margin.", words: heard))
        XCTAssertEqual(cut.cutAtMs, 1_000, "never earlier than the end of the last word kept")
        // A gap bigger than the lead keeps the 150 ms.
        var gap = heard
        gap[3].startMs = 1_400; gap[3].endMs = 1_700; gap[4].startMs = 1_700; gap[4].endMs = 2_100
        XCTAssertEqual(MarginEndPhrase.cut(text: "That is it. Stop margin.", words: gap)?.cutAtMs, 1_250)
        // Words that overlap the phrase keep everything.
        var overlap = heard
        overlap[2].endMs = 1_100
        XCTAssertNil(MarginEndPhrase.cut(text: "That is it. Stop margin.", words: overlap))
    }

    func testAZeroLengthWordHoldingMoreThanThePhraseIsNotSplit() {
        let heard = [
            MarginEndPhraseWord(text: "um", startMs: 0, endMs: 300),
            MarginEndPhraseWord(text: "okay stop", startMs: 400, endMs: 400),
            MarginEndPhraseWord(text: "margin", startMs: 500, endMs: 900)
        ]
        XCTAssertNil(MarginEndPhrase.cut(text: "Um okay stop margin", words: heard), "\"okay\" would be lost")
        var short = heard
        short[1] = MarginEndPhraseWord(text: "okay-stop", startMs: 400, endMs: 402)
        XCTAssertNil(MarginEndPhrase.cut(text: "Um okay stop margin", words: short))
    }

    func testAnOpeningQuoteOrDashBeforeThePhraseGoesWithIt() throws {
        let heard = words(["he", "said", "stop", "margin"])
        XCTAssertEqual(MarginEndPhrase.cut(text: "He said \"stop margin\"", words: heard)?.text, "He said")
        XCTAssertEqual(MarginEndPhrase.cut(text: "He said \u{201C}stop margin\u{201D}", words: heard)?.text, "He said")
        XCTAssertEqual(MarginEndPhrase.cut(text: "He said \u{2014} stop margin.", words: heard)?.text, "He said")
        XCTAssertEqual(MarginEndPhrase.cut(text: "He said, stop margin.", words: heard)?.text, "He said,", "A comma stays")
    }

    /// The audit's rows: only what leads into the phrase goes; the listener's own quotes, apostrophes and the start
    /// of the text stay.
    func testTheListenersOwnQuotesApostrophesAndStartOfTextStay() throws {
        func kept(_ text: String, _ spoken: [String]) -> String? {
            MarginEndPhrase.cut(text: text, words: words(spoken + ["stop", "margin"]))?.text
        }
        XCTAssertEqual(kept("\"Hello,\" she said. Stop margin.", ["hello", "she", "said"]), "\"Hello,\" she said.")
        XCTAssertEqual(kept("He said \"no\" stop margin", ["he", "said", "no"]), "He said \"no\"")
        XCTAssertEqual(kept("The players' stop margin", ["the", "players'"]), "The players'")
        XCTAssertEqual(kept("He said 'no' stop margin", ["he", "said", "no"]), "He said 'no'")
        XCTAssertEqual(kept("(Aside) it was fine stop margin", ["aside", "it", "was", "fine"]), "(Aside) it was fine")
        XCTAssertEqual(kept("-5 degrees today stop margin", ["5", "degrees", "today"]), "-5 degrees today")
        XCTAssertEqual(kept("'Tis fine stop margin", ["tis", "fine"]), "'Tis fine")
        XCTAssertEqual(kept("It was 10-stop margin", ["it", "was", "10"]), "It was 10-", "A dash joined to a word stays")
        XCTAssertEqual(kept("He said \u{2014} \"stop margin\"", ["he", "said"]), "He said")
    }
}
