import Foundation
import XCTest
@testable import SessionKit

/// #1680: on a hot phone the bundled voice holds narration; saved Supertonic audio plays only as a whole run from a
/// seam, so the voice never bounces back and forth.
final class SavedVoiceRunRuleTests: XCTestCase {
    func testALongSavedRunAtASeamSwitchesToSupertonic() {
        let run = Array(repeating: 20.0, count: 15) // 5 minutes
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: false, playbackRate: 1),
                       .savedSupertonic)
    }

    func testAShortSavedRunKeepsTheBundledVoice() {
        let run = Array(repeating: 20.0, count: 14) // 4 min 40 s
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: false, playbackRate: 1),
                       .bundledVoice)
    }

    func testAShortRunToTheEndOfTheItemSwitches() {
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: [20], reachesEnd: true, playbackRate: 1),
                       .savedSupertonic)
    }

    func testNoSwitchMidParagraph() {
        let run = Array(repeating: 20.0, count: 30)
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: false, savedRun: run, reachesEnd: true, playbackRate: 1),
                       .bundledVoice)
    }

    func testFiveMinutesIsListeningTimeAtTheListenersSpeed() {
        let run = Array(repeating: 20.0, count: 15) // 5 minutes of audio, 2.5 minutes at 2x
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: false, playbackRate: 2),
                       .bundledVoice)
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: false, playbackRate: 0.75),
                       .savedSupertonic)
    }

    func testOnceSwitchedItStaysToTheEndOfTheRunThenGoesBack() {
        // Inside the run, any saved chunk plays, seam or not, however little is left.
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: true, atSeam: false, savedRun: [20], reachesEnd: false, playbackRate: 1),
                       .savedSupertonic)
        // The run ends at the first chunk without saved audio.
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: true, atSeam: true, savedRun: [], reachesEnd: false, playbackRate: 1),
                       .bundledVoice)
    }

    /// #2131: the rule's edges, each of which survived a mutation of `SavedVoiceRunRule.swift` with every test above passing.
    func testASlowSpeedMakesALessLongRunLongEnough() {
        let run = Array(repeating: 20.0, count: 12) // 4 minutes of audio: 5 min 20 s of listening at 0.75x
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: false, playbackRate: 0.75),
                       .savedSupertonic, "a long-enough saved run at 0.75x must not stay on the bundled voice")
        XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: false, playbackRate: 1),
                       .bundledVoice, "the same run at 1x is 4 minutes of listening")
    }

    func testTheSpeedIsClampedAtAQuarter() {
        let belowTheClamp = [74.0] // 296 s at the clamped 0.25x; 740 s if the rate were used as given
        for rate in [0.25, 0.1, 0.0, -1.0, .nan] {
            XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: belowTheClamp, reachesEnd: false, playbackRate: rate),
                           .bundledVoice, "rate \(rate) counts as 0.25x")
            XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: [75], reachesEnd: false, playbackRate: rate),
                           .savedSupertonic, "75 s at 0.25x is exactly five minutes (rate \(rate))")
        }
    }

    func testAZeroLengthFirstSavedChunkNeverStartsOrKeepsARun() {
        let long = Array(repeating: 20.0, count: 30)
        for inSavedRun in [false, true] {
            XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: inSavedRun, atSeam: true, savedRun: [0] + long, reachesEnd: true, playbackRate: 1),
                           .bundledVoice, "a chunk with no audio ends the run (inSavedRun \(inSavedRun))")
            XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: inSavedRun, atSeam: true, savedRun: [0], reachesEnd: true, playbackRate: 1),
                           .bundledVoice)
            XCTAssertEqual(SavedVoiceRunRule.choice(inSavedRun: inSavedRun, atSeam: true, savedRun: [-1] + long, reachesEnd: true, playbackRate: 1),
                           .bundledVoice, "a negative length is no audio")
        }
    }

    func testARunExactlyFiveMinutesLongSwitches() {
        XCTAssertTrue(SavedVoiceRunRule.isLongEnough([150, 150], reachesEnd: false, playbackRate: 1))
        XCTAssertFalse(SavedVoiceRunRule.isLongEnough([150, 149.9], reachesEnd: false, playbackRate: 1))
        XCTAssertFalse(SavedVoiceRunRule.isLongEnough([], reachesEnd: true, playbackRate: 1), "an empty run reaches nothing")
    }

    func testParagraphSeams() {
        let text = "First paragraph ends here.\n\nSecond one starts. It goes on.\nThird."
        func offset(_ word: String) -> Int { text.distance(from: text.startIndex, to: text.range(of: word)!.lowerBound) }
        XCTAssertTrue(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: nil, start: 0), "where the text starts")
        XCTAssertTrue(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: 0, start: offset("Second")))
        XCTAssertTrue(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: 0, start: offset("ends") + 10), "inside the break")
        XCTAssertTrue(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: 0, start: offset("It goes")),
                      "the first boundary after a break that sits inside the previous chunk")
        XCTAssertFalse(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: offset("Second"), start: offset("It goes")))
        XCTAssertTrue(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: offset("It goes"), start: offset("Third")))
        XCTAssertFalse(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: 5, start: 5))
        XCTAssertFalse(SavedVoiceRunRule.isParagraphSeam(in: text, previousStart: 0, start: text.count + 1))
        XCTAssertFalse(SavedVoiceRunRule.isParagraphSeam(in: "", previousStart: 0, start: 1))
    }

    /// The player plans chunks on the spoken text, which has its line breaks turned into spaces, so seams are read in
    /// the source text at the chunks' source offsets: each paragraph after the first gives exactly one seam, at the
    /// first sentence boundary after its break, never mid-sentence.
    func testPlannedChunksGiveOneSeamPerParagraphAtASentenceEnd() {
        func seams(_ article: String, budget: Int = RenderedSpeechChunker.spokenCostBudget) -> [Int] {
            let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(article)
            let chunks = NarrationChunkPlanner.spokenPlan(
                spokenText: projection.text, articleText: nil, articleSpokenStart: 0, budget: budget).chunks
            XCTAssertGreaterThan(chunks.count, 3)
            return chunks.indices.filter { index in
                SavedVoiceRunRule.isParagraphSeam(
                    in: article, at: index,
                    sourceStart: { projection.sourceOffset(atSpokenCharacterOffset: chunks[$0].startOffset) },
                    endsSentence: { chunks[$0].boundary == .sentence || chunks[$0].boundary == .hard })
            }.map { index in
                if index > 0 { XCTAssertEqual(chunks[index - 1].boundary, .sentence, "chunk \(index) starts mid-sentence") }
                return index
            }
        }
        let paragraph = "The committee met on Tuesday to discuss the proposal, which had been circulating for weeks. Most of the objections concerned cost."
        let article = (1...4).map { "Section \($0). " + paragraph }.joined(separator: "\n\n")
        XCTAssertEqual(seams(article).count, 4)
        XCTAssertEqual(seams(article).first, 0)
        XCTAssertEqual(seams(article.replacingOccurrences(of: "\n\n", with: " ")), [0], "no line breaks, no seams after the start")
        // Long sentences split at commas: a seam still waits for a sentence end.
        let long = "One clause runs on, and another follows it, and a third comes after that, and it keeps going a while longer."
        let commas = (1...4).map { _ in long }.joined(separator: "\n\n")
        XCTAssertEqual(seams(commas, budget: 60).count, 4)
    }

    func testASeamWaitsForTheSentenceToEnd() {
        let text = "Ends here.\n\nNew paragraph, with a comma, and more. Next sentence."
        let starts = [0, text.distance(from: text.startIndex, to: text.range(of: "with")!.lowerBound),
                      text.distance(from: text.startIndex, to: text.range(of: "Next")!.lowerBound)]
        let sentence = [false, true, true]
        func seam(_ index: Int) -> Bool {
            SavedVoiceRunRule.isParagraphSeam(in: text, at: index, sourceStart: { starts[$0] }, endsSentence: { sentence[$0] })
        }
        XCTAssertTrue(seam(0))
        XCTAssertFalse(seam(1), "the chunk before ends at a comma")
        XCTAssertTrue(seam(2), "the first sentence end after the break")
    }
}
