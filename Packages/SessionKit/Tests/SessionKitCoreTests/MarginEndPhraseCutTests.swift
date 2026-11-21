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
        XCTAssertEqual(cut.cutAtMs, 1_600 - 150)
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

    func testACutAtTheVeryStartWouldLeaveNoAudioSoItKeepsAll() {
        // The phrase starts 120 ms in: 150 ms before it is the start, so the cut would be empty.
        XCTAssertNil(MarginEndPhrase.cut(text: "Um stop margin", words: words(["um", "stop", "margin"], from: 0, wordMs: 100, gapMs: 20)))
    }
}
