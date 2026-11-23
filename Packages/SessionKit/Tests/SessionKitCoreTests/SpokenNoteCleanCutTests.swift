import Foundation
import XCTest
@testable import SessionKit

/// #4779: where a spoken note is cut for its version without ums, and how its clock maps to the recording's.
final class SpokenNoteCleanCutTests: XCTestCase {
    private func word(_ text: String, _ start: Int, _ end: Int) -> SpokenNoteTimedWord {
        SpokenNoteTimedWord(text: text, startMs: start, endMs: end)
    }

    /// Quiet everywhere except the given spans.
    private func flags(durationMs: Int, loud: [Range<Int>]) -> [Bool] {
        (0..<(durationMs / 20)).map { index in
            let window = (index * 20)..<(index * 20 + 20)
            return !loud.contains { $0.overlaps(window) }
        }
    }

    private func removed(_ cut: SpokenNoteTakeCut) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var cursor = 0
        for span in cut.kept {
            if span.startMs > cursor { ranges.append(cursor..<span.startMs) }
            cursor = span.endMs
        }
        if cursor < cut.durationMs { ranges.append(cursor..<cut.durationMs) }
        return ranges
    }

    func testFillerTable() {
        let fillers = ["um", "Um,", "UM", "umm", "uh.", "Uhm", "ah", "er", "erm", "Uh?", "\"um\""]
        let words = ["uh-huh", "mm-hmm", "her", "error", "umbrella", "huh", "hmm", "a", "I", "", "Uh-um", "summer", "ahead"]
        for text in fillers { XCTAssertTrue(SpokenNoteCleanPolicy.isFiller(text), text) }
        for text in words { XCTAssertFalse(SpokenNoteCleanPolicy.isFiller(text), text) }
    }

    func testIsolatedYouKnowIsCutAndYouKnowWhatIsKept() {
        let alone = [word("It", 0, 200), word("was,", 200, 400), word("you", 400, 550), word("know,", 550, 700), word("fine.", 700, 900)]
        XCTAssertEqual(SpokenNoteCleanPolicy.fillerSpans(in: alone), [400..<700])
        let what = [word("And", 0, 200), word("you", 450, 550), word("know", 550, 700), word("what", 700, 900), word("happened.", 900, 1200)]
        XCTAssertEqual(SpokenNoteCleanPolicy.fillerSpans(in: what), [])
    }

    func testEmptyTakeCutsNothingAndKeepsNothing() {
        let cut = SpokenNoteTakeCut.make(words: [], silentFlags: [], durationMs: 0)
        XCTAssertEqual(cut.kept, [])
        XCTAssertEqual(cut.keptMs, 0)
    }

    func testAllSilentTakeKeepsOnlyAShortenedPause() {
        let cut = SpokenNoteTakeCut.make(words: [], silentFlags: Array(repeating: true, count: 250), durationMs: 5_000)
        XCTAssertEqual(cut.kept, [.init(startMs: 0, endMs: 250), .init(startMs: 4_750, endMs: 5_000)])
        XCTAssertEqual(cut.keptMs, SpokenNoteCleanPolicy.keptPauseMs)
        XCTAssertEqual(cut.pausesShortened, 1)
    }

    func testUmOnlySentenceIsCutAndItsSentenceStartsAtTheNextKeptMoment() {
        // "Hello." 0-1000, "Um." 1500-1800, "Bye." 2300-3000. The pauses around the um are each 500 ms, so the um alone
        // is cut and the quiet run it joins (1000-2300, 1300 ms) is shortened to 250 + 250.
        let words = [word("Hello.", 0, 1_000), word("Um.", 1_500, 1_800), word("Bye.", 2_300, 3_000)]
        let cut = SpokenNoteTakeCut.make(
            words: words, silentFlags: flags(durationMs: 3_000, loud: [0..<1_000, 1_500..<1_800, 2_300..<3_000]), durationMs: 3_000
        )
        XCTAssertEqual(removed(cut), [1_250..<2_050])
        XCTAssertEqual(cut.fillersRemoved, 1)
        XCTAssertEqual(cut.pausesShortened, 1)

        let take = SpokenNoteTake(id: "t1", audioFileName: "take-1.m4a", durationMs: 3_000, createdAt: Date(timeIntervalSince1970: 0), sentences: [
            SpokenNoteSentence(text: "Hello.", startMs: 0, endMs: 1_000),
            SpokenNoteSentence(text: "Um.", startMs: 1_500, endMs: 1_800),
            SpokenNoteSentence(text: "Bye.", startMs: 2_300, endMs: 3_000)
        ])
        let note = SpokenNote(id: "n1", takes: [take])
        let layout = SpokenNoteWholeAudioLayout(
            requested: [.init(id: "t1", audioFileName: "take-1.m4a", durationMs: 3_000)],
            placed: [.init(takeId: "t1", startMs: 0, durationMs: 3_000)], durationMs: 3_000
        )
        let map = SpokenNoteCleanMap(placements: placements(for: [("t1", cut)]), recorded: layout, cleanDurationMs: cut.keptMs)
        let timeline = SpokenNoteWholeTimeline(note: note, layout: layout, map: map)
        XCTAssertEqual(timeline.entries.map(\.segmentId), SpokenNoteWholeTimeline(note: note, layout: layout).entries.map(\.segmentId))
        XCTAssertEqual(timeline.entries[1].startMs, 1_250)
        XCTAssertEqual(timeline.entries[1].endMs, 1_251)
        XCTAssertEqual(timeline.entries[2].startMs, 1_250 + 250)
        XCTAssertEqual(timeline.durationMs, 2_200)
    }

    func testFillerBetweenTwoPausesBecomesOneShortenedPause() {
        // Speech 0-1000, quiet 1000-1600, "um" 1600-1900, quiet 1900-2500, speech 2500-3500.
        let words = [word("So", 0, 1_000), word("um", 1_600, 1_900), word("then", 2_500, 3_500)]
        let cut = SpokenNoteTakeCut.make(
            words: words, silentFlags: flags(durationMs: 3_500, loud: [0..<1_000, 1_600..<1_900, 2_500..<3_500]), durationMs: 3_500
        )
        XCTAssertEqual(removed(cut), [1_250..<2_250])
        XCTAssertEqual(cut.keptMs, 3_500 - 1_000)
    }

    func testPauseUnderASecondIsUntouched() {
        let words = [word("One.", 0, 1_000), word("Two.", 1_900, 3_000)]
        let cut = SpokenNoteTakeCut.make(words: words, silentFlags: flags(durationMs: 3_000, loud: [0..<1_000, 1_900..<3_000]), durationMs: 3_000)
        XCTAssertTrue(cut.removesNothing)
    }

    func testThirtySecondPauseKeepsHalfASecond() {
        let words = [word("One.", 0, 1_000), word("Two.", 31_000, 32_000)]
        let cut = SpokenNoteTakeCut.make(words: words, silentFlags: flags(durationMs: 32_000, loud: [0..<1_000, 31_000..<32_000]), durationMs: 32_000)
        XCTAssertEqual(removed(cut), [1_250..<30_750])
        XCTAssertEqual(cut.keptMs, 2_000 + 500)
    }

    func testAQuietWordInsideALongQuietRunKeepsTheRun() {
        // The level says quiet, but the transcriber heard a word in the middle: nothing is cut.
        let words = [word("One.", 0, 1_000), word("soft", 2_000, 2_300), word("Two.", 4_000, 5_000)]
        let cut = SpokenNoteTakeCut.make(words: words, silentFlags: flags(durationMs: 5_000, loud: [0..<1_000, 4_000..<5_000]), durationMs: 5_000)
        XCTAssertTrue(cut.removesNothing)
    }

    func testMapRoundTripsAndMapsCutTimesToTheNextKeptStart() {
        let cutA = SpokenNoteTakeCut(durationMs: 10_000, kept: [.init(startMs: 0, endMs: 3_000), .init(startMs: 5_000, endMs: 10_000)], fillersRemoved: 1, pausesShortened: 0)
        let cutB = SpokenNoteTakeCut(durationMs: 4_000, kept: [.init(startMs: 1_000, endMs: 4_000)], fillersRemoved: 1, pausesShortened: 0)
        let layout = SpokenNoteWholeAudioLayout(
            requested: [.init(id: "a", audioFileName: "take-a.m4a", durationMs: 10_000), .init(id: "b", audioFileName: "take-b.m4a", durationMs: 4_000)],
            placed: [.init(takeId: "a", startMs: 0, durationMs: 10_000), .init(takeId: "b", startMs: 10_000, durationMs: 4_000)],
            durationMs: 14_000
        )
        let map = SpokenNoteCleanMap(placements: placements(for: [("a", cutA), ("b", cutB)]), recorded: layout, cleanDurationMs: 11_000)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 0), 0)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 2_999), 2_999)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 4_000), 3_000, "inside a cut goes to the next kept start")
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 7_000), 5_000)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 10_500), 8_000, "the cut start of take b")
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 12_000), 9_000)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 20_000), 11_000, "past the end is the end")
        for clean in stride(from: 0, to: 11_000, by: 37) {
            XCTAssertEqual(map.cleanMs(fromRecordedMs: map.recordedMs(fromCleanMs: clean)), clean, "\(clean)")
        }
    }

    /// `long-source`: a two-hour note of about 18,000 words, 1,500 fillers and 600 long pauses.
    func testTwoHourNoteCutListsStaySmallAndLookupsStayLogarithmic() throws {
        let durationMs = 2 * 60 * 60 * 1_000
        var words: [SpokenNoteTimedWord] = []
        var loud: [Range<Int>] = []
        var t = 0
        var fillerCount = 0, pauseCount = 0, index = 0
        while t < durationMs - 3_000, words.count < 18_000 + 1_500 {
            index += 1
            let isFiller = index % 13 == 0 && fillerCount < 1_500
            let text = isFiller ? "um" : "word"
            words.append(word(text, t, t + 250))
            loud.append(t..<(t + 250))
            if isFiller { fillerCount += 1 }
            t += 250 + 60
            if index % 31 == 0 && pauseCount < 600 { t += 2_000; pauseCount += 1 }
        }
        XCTAssertGreaterThanOrEqual(fillerCount, 1_400)
        XCTAssertGreaterThanOrEqual(pauseCount, 590)
        var silent = Array(repeating: true, count: durationMs / 20)
        for span in loud { for w in (span.lowerBound / 20)..<min(silent.count, (span.upperBound + 19) / 20) { silent[w] = false } }
        let cut = SpokenNoteTakeCut.make(words: words, silentFlags: silent, durationMs: durationMs)
        let bytes = try JSONEncoder().encode(cut).count
        XCTAssertLessThan(bytes, 200_000)
        XCTAssertGreaterThan(cut.kept.count, 2_000)

        let layout = SpokenNoteWholeAudioLayout(
            requested: [.init(id: "t", audioFileName: "take-t.m4a", durationMs: durationMs)],
            placed: [.init(takeId: "t", startMs: 0, durationMs: durationMs)], durationMs: durationMs
        )
        let map = SpokenNoteCleanMap(placements: placements(for: [("t", cut)]), recorded: layout, cleanDurationMs: cut.keptMs)
        let ceiling = Int(log2(Double(map.pieceCount)).rounded(.up)) + 2
        for recorded in stride(from: 0, to: durationMs, by: 9_973) {
            XCTAssertLessThanOrEqual(map.cleanMsCounting(fromRecordedMs: recorded).comparisons, ceiling)
        }
        for clean in stride(from: 0, to: cut.keptMs, by: 7_919) {
            XCTAssertLessThanOrEqual(map.recordedMsCounting(fromCleanMs: clean).comparisons, ceiling)
        }
    }

    /// Placements as a gapless render lays the kept spans down, take after take.
    private func placements(for cuts: [(String, SpokenNoteTakeCut)]) -> [SpokenNoteCleanPlacement] {
        var output = 0
        var result: [SpokenNoteCleanPlacement] = []
        for (id, cut) in cuts {
            for span in cut.kept {
                result.append(SpokenNoteCleanPlacement(takeId: id, takeStartMs: span.startMs, takeEndMs: span.endMs, outputStartMs: output))
                output += span.lengthMs
            }
        }
        return result
    }
}
