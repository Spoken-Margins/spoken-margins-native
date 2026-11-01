import Foundation
import XCTest
@testable import SessionKit

final class SpokenNoteSentenceGroupingTests: XCTestCase {
    /// Words spoken 400 ms apart, each 300 ms long, unless a gap is given.
    private func words(_ texts: [String], from start: Int = 0, gapMs: Int = 100) -> [AlignedTranscriptSegment] {
        var cursor = start
        return texts.enumerated().map { index, text in
            defer { cursor += 300 + gapMs }
            return AlignedTranscriptSegment(id: "w\(index)", text: text, startMs: cursor, endMs: cursor + 300)
        }
    }

    private func group(_ text: String, gapMs: Int = 100) -> [SpokenNoteSentence] {
        SpokenNoteSentenceGrouping.sentences(from: words(text.split(separator: " ").map(String.init), gapMs: gapMs))
    }

    func testEndPunctuationBreaksSentencesAndTimesSpanTheirWords() {
        let result = group("Buy milk. Call Sam! Is it Friday?")
        XCTAssertEqual(result.map(\.text), ["Buy milk.", "Call Sam!", "Is it Friday?"])
        XCTAssertEqual(result[0].startMs, 0)
        XCTAssertEqual(result[0].endMs, 700)      // second word: 400...700
        XCTAssertEqual(result[1].startMs, 800)
        XCTAssertEqual(result[2].endMs, 2_700)
    }

    func testClosingQuotesAndEllipsesStillEndTheSentence() {
        XCTAssertEqual(group("She said \"stop.\" Then left… Okay").map(\.text), ["She said \"stop.\"", "Then left…", "Okay"])
    }

    func testInitialsAbbreviationsAndNumbersDoNotBreak() {
        XCTAssertEqual(group("Ask J. Smith about Dr. Lee, e.g. Tuesday. Pay 3.50 today.").map(\.text),
                       ["Ask J. Smith about Dr. Lee, e.g. Tuesday.", "Pay 3.50 today."])
    }

    func testWordsThatReallyEndSentencesBreakEvenWhenTheyLookLikeAbbreviations() {
        XCTAssertEqual(group("Are we ready? No. I said no. So did I. Fine.").map(\.text),
                       ["Are we ready?", "No.", "I said no.", "So did I.", "Fine."])
    }

    func testAnOpeningBracketOrQuoteDoesNotHideAnAbbreviationOrInitial() {
        XCTAssertEqual(group("Ask (Dr. Lee) or “J. Smith” today.").map(\.text), ["Ask (Dr. Lee) or “J. Smith” today."])
    }

    func testAPauseBreaksUnpunctuatedDictation() {
        let first = words(["remember", "to", "call"])
        let second = words(["also", "buy", "bread"], from: (first.last?.endMs ?? 0) + SpokenNoteSentenceGrouping.pauseBreakMs)
        let result = SpokenNoteSentenceGrouping.sentences(from: first + second)
        XCTAssertEqual(result.map(\.text), ["remember to call", "also buy bread"])
        let justUnder = SpokenNoteSentenceGrouping.sentences(from: first + words(["also"], from: (first.last?.endMs ?? 0) + SpokenNoteSentenceGrouping.pauseBreakMs - 1))
        XCTAssertEqual(justUnder.map(\.text), ["remember to call also"])
    }

    func testALongRunWithNoPunctuationOrPauseIsCutIntoPieces() {
        let many = (1...(SpokenNoteSentenceGrouping.maxWordsPerSentence * 2 + 5)).map { "w\($0)" }
        let result = SpokenNoteSentenceGrouping.sentences(from: words(many))
        XCTAssertEqual(result.map { $0.text.split(separator: " ").count }, [40, 40, 5])
    }

    func testNoDictatedTextIsEverLost() {
        let input = ["Um,", "so", "", "  ", "the", "plan.", "(Maybe", "later?)", "Yes", "e.g.", "", "tomorrow"]
        let result = SpokenNoteSentenceGrouping.sentences(from: words(input))
        XCTAssertEqual(result.map(\.text).joined(separator: " "), input.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " "))
    }

    func testWordsOutOfOrderAreSpokenOrderAndEqualStartsKeepTheirOrder() {
        let shuffled = [
            AlignedTranscriptSegment(id: "c", text: "three.", startMs: 2_300, endMs: 2_600),
            AlignedTranscriptSegment(id: "a", text: "one", startMs: 0, endMs: 300),
            AlignedTranscriptSegment(id: "b1", text: "two", startMs: 400, endMs: 700),
            AlignedTranscriptSegment(id: "b2", text: "and", startMs: 400, endMs: 700),
        ]
        XCTAssertEqual(SpokenNoteSentenceGrouping.sentences(from: shuffled).map(\.text), ["one two and", "three."])
    }

    func testNegativeAndBackwardsTimesAreClampedByTheSentenceType() {
        let odd = [AlignedTranscriptSegment(id: "x", text: "Hi.", startMs: -50, endMs: -80)]
        let result = SpokenNoteSentenceGrouping.sentences(from: odd)
        XCTAssertEqual(result, [SpokenNoteSentence(text: "Hi.", startMs: 0, endMs: 0)])
    }

    func testNothingSpokenGivesNoSentences() {
        XCTAssertEqual(SpokenNoteSentenceGrouping.sentences(from: []), [])
        XCTAssertEqual(SpokenNoteSentenceGrouping.sentences(from: words(["", " "])), [])
    }

    func testGroupedSentencesFeedATakeThatMapsBackToItsAudio() {
        var note = SpokenNote(id: "n")
        note.appendTake(SpokenNoteTake(id: "t", audioFileName: "t.m4a", durationMs: 5_000, createdAt: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(note.setTranscript(group("First thing. Second thing."), forTake: "t"))
        let ref = note.sentence(inTake: "t", atMs: 1_000)
        XCTAssertEqual(ref.flatMap { note.sentence($0)?.text }, "Second thing.")
    }
}
