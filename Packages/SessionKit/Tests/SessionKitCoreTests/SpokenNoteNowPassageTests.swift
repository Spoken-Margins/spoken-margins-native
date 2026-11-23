import Foundation
import XCTest
@testable import SessionKit

/// #4780: a spoken note's own words on the Now tab. Its rows are the note's sentences (broken at pauses, not only at
/// stops), the lit row comes from the playback clock and the note's timeline (a pause keeps the sentence just heard),
/// and its Margins are rows after their sentences, placed by segment id.
final class SpokenNoteNowPassageTests: XCTestCase {
    private typealias Words = SpokenNoteNowPassage.Words
    private let noteId = "note-1"
    private var itemId: String { SpokenNoteItem.itemId(forNoteId: noteId) }

    // MARK: fixtures

    /// Takes of (id, duration, sentences as (text, startMs, endMs) within the take).
    private func note(_ takes: [(String, Int, [(String, Int, Int)])]) -> SpokenNote {
        var note = SpokenNote(id: noteId)
        for (id, duration, sentences) in takes {
            note.appendTake(SpokenNoteTake(
                id: id, audioFileName: "take-\(id).m4a", durationMs: duration, createdAt: Date(timeIntervalSince1970: 0),
                sentences: sentences.map { SpokenNoteSentence(text: $0.0, startMs: $0.1, endMs: $0.2) }))
        }
        return note
    }

    /// The takes laid end to end, each placed for its full duration.
    private func timeline(_ note: SpokenNote) -> SpokenNoteWholeTimeline {
        var start = 0
        var placed: [SpokenNoteWholeAudioLayout.Placed] = []
        for take in note.takes {
            placed.append(.init(takeId: take.id, startMs: start, durationMs: take.durationMs))
            start += take.durationMs
        }
        return SpokenNoteWholeTimeline(note: note, layout: SpokenNoteWholeAudioLayout(requested: [], placed: placed, durationMs: start))
    }

    private func twoTakes() -> SpokenNote {
        note([
            ("a", 10_000, [("First thought.", 0, 2_000), ("Second thought.", 4_000, 6_000)]),
            ("b", 10_000, [("Third thought.", 0, 2_000), ("Fourth thought.", 5_000, 7_000)])
        ])
    }

    private func anchor(segmentId: String?, timeMs: Int?, startChar: Int = 0) -> Anchor {
        Anchor(anchorType: .transcript, startChar: startChar, endChar: startChar, anchorBefore: "", anchorAfter: "",
               mediaTimeMs: timeMs, transcriptSegmentId: segmentId)
    }

    private func margin(_ id: String, anchor: Anchor, at seconds: Double, status: String = "active", item: String? = nil,
                        target: InterjectionTargetType = .item) -> Interjection {
        Interjection(
            id: id, itemId: item ?? itemId, sessionId: "session", targetType: target, targetId: item ?? itemId,
            createdAt: Date(timeIntervalSince1970: seconds), roughPercent: 50, anchor: anchor, audioPath: nil, audioStatus: "none",
            transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil, displayText: "A Margin", status: status)
    }

    private func shownIds(_ state: PlaybackNowSceneState) -> [Int] {
        state.shownItems.compactMap(\.sentence).map(\.id)
    }

    // MARK: text and rows

    func testWordsTextMatchesTheTimelinesText() {
        let note = twoTakes()
        let timeline = timeline(note)
        let words = Words(note: note, timeline: timeline)
        XCTAssertEqual(words.text, timeline.text)
        XCTAssertEqual(words.text, "First thought. Second thought. Third thought. Fourth thought.")
        XCTAssertEqual(Words(note: note, timeline: nil).text, timeline.text, "no timeline, the same text")
    }

    func testRowIdsAreTheScenesSentenceIds() {
        let note = note([("a", 20_000, [
            ("Opening words.", 0, 1_000), ("  leading space here", 2_000, 3_000), ("   ", 4_000, 4_500), ("", 5_000, 5_100),
            ("After the empty ones.", 6_000, 7_000)
        ])])
        let words = Words(note: note, timeline: timeline(note))
        XCTAssertEqual(words.rows.count, 3, "a sentence of only space, or an empty one, gives no row")
        var state = PlaybackNowSceneState(text: words.text, sentenceStarts: words.sentenceStarts, isNote: true)
        state.move(offset: words.sentenceStarts[0])
        XCTAssertEqual(shownIds(state), words.rows.map(\.id))
        let chars = Array(words.text)
        for row in words.rows { XCTAssertFalse(chars[row.id].isWhitespace, "a row's id is its first non-space Character") }
        XCTAssertEqual(state.shownItems.compactMap(\.sentence).map(\.text), ["Opening words.", "leading space here", "After the empty ones."])
    }

    func testUnpunctuatedDictationKeepsTheNotesSentences() {
        let long = String(repeating: "and then we kept on talking about it ", count: 4) // about 150 Characters, no stop
        let note = note([("a", 30_000, [(long + "one", 0, 5_000), (long + "two", 6_000, 11_000), (long + "three", 12_000, 17_000)])])
        let words = Words(note: note, timeline: timeline(note))
        XCTAssertGreaterThan(words.text.count, PlaybackLivePassage.maxSentenceLength)
        var noteScene = PlaybackNowSceneState(text: words.text, sentenceStarts: words.sentenceStarts, isNote: true)
        noteScene.move(offset: 0)
        XCTAssertEqual(noteScene.shownScene.sentences.count, 3, "the note's own three sentences")
        var splitScene = PlaybackNowSceneState(text: words.text)
        splitScene.move(offset: 0)
        XCTAssertNotEqual(splitScene.shownScene.sentences.count, 3, "the article splitter would cut them differently")
    }

    // MARK: the lit row

    func testAPauseBetweenSentencesKeepsTheSentenceJustHeard() {
        let note = twoTakes()
        let words = Words(note: note, timeline: timeline(note))
        // "Second thought." runs 4,000-6,000; the 2 s gap before it keeps "First thought." lit.
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 3_000), words.sentenceStarts[0])
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 4_000), words.sentenceStarts[1])
        // The tail of take a (6,000-10,000) keeps "Second thought."; take b starts at 10,000.
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 9_999), words.sentenceStarts[1])
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 10_000), words.sentenceStarts[2])
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 16_000), words.sentenceStarts[3])
        XCTAssertNil(words.sourceOffset(mediaTimeMs: nil))
    }

    func testBeforeTheFirstWordedSentenceThereIsNoOffset() {
        let note = note([("a", 10_000, [("Late start.", 3_000, 5_000)])])
        let words = Words(note: note, timeline: timeline(note))
        XCTAssertNil(words.sourceOffset(mediaTimeMs: 0))
        XCTAssertNil(words.sourceOffset(mediaTimeMs: 2_999))
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 3_000), 0)
        XCTAssertNil(Words(note: note, timeline: nil).sourceOffset(mediaTimeMs: 4_000), "no timeline, nothing lit")
    }

    func testATakeWithNoWordsKeepsThePreviousSentence() {
        let note = note([
            ("a", 10_000, [("Only sentence of a.", 0, 2_000)]),
            ("silent", 10_000, []),
            ("c", 10_000, [("Take c speaks.", 1_000, 3_000)])
        ])
        let words = Words(note: note, timeline: timeline(note))
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 15_000), words.sentenceStarts[0], "inside the silent take")
        XCTAssertEqual(words.sourceOffset(mediaTimeMs: 21_000), words.sentenceStarts[1])
    }

    func testTwoHourNoteLooksUpLikeALinearScan() {
        let takes = (0..<40).map { take -> (String, Int, [(String, Int, Int)]) in
            ("t\(take)", 180_000, (0..<50).map { ("Sentence \(take)-\($0) is here.", $0 * 3_600, $0 * 3_600 + 3_000) })
        }
        let note = note(takes)
        let timeline = timeline(note)
        let words = Words(note: note, timeline: timeline)
        XCTAssertEqual(words.rows.count, 2_000)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let time = Int.random(in: -1_000...(timeline.durationMs + 1_000), using: &generator)
            let expected = timeline.entries.last(where: { $0.startMs <= time }).map { words.row(id: $0.startChar)?.id }
            let got = words.sourceOffset(mediaTimeMs: time)
            XCTAssertEqual(got, expected ?? nil, "at \(time) ms")
        }
        measure { for time in stride(from: 0, to: timeline.durationMs, by: 3_600) { _ = words.sourceOffset(mediaTimeMs: time) } }
    }

    // MARK: following through short sentences and gaps

    func testRowsCrossedIncludeSentencesWithoutAudio() {
        // Take b's second sentence starts after its audio ends, so it has no timeline entry.
        let note = note([
            ("a", 10_000, [("One.", 0, 1_000), ("Two.", 2_000, 3_000)]),
            ("b", 5_000, [("Three.", 0, 1_000), ("No audio.", 6_000, 7_000)]),
            ("c", 5_000, [("Five.", 0, 1_000)])
        ])
        let words = Words(note: note, timeline: timeline(note))
        XCTAssertNil(words.rows[3].startMs)
        let starts = words.sentenceStarts
        XCTAssertEqual(words.rowsCrossed(fromOffset: starts[2], toOffset: starts[4]), [starts[3], starts[4]])
        XCTAssertEqual(words.rowsCrossed(fromOffset: nil, toOffset: starts[4]), [starts[4]])
        XCTAssertEqual(words.rowsCrossed(fromOffset: starts[4], toOffset: starts[1]), [starts[1]], "a move back is one move")
        XCTAssertEqual(words.rowsCrossed(fromOffset: starts[1], toOffset: starts[1]), [starts[1]])
    }

    func testAShortSentenceBetweenTicksIsNotAJump() {
        let note = note([("a", 10_000, [("Long opening sentence.", 0, 1_000), ("Yes.", 1_100, 1_400), ("Then more words.", 1_500, 3_000)])])
        let words = Words(note: note, timeline: timeline(note))
        var state = PlaybackNowSceneState(text: words.text, sentenceStarts: words.sentenceStarts, isNote: true)
        state.move(offset: words.sourceOffset(mediaTimeMs: 900)!)
        state.listenerScrolled()
        XCTAssertFalse(state.follow.isFollowing)
        // One tick goes from 900 ms to 1,600 ms, past the 300 ms "Yes.".
        let from = words.sourceOffset(mediaTimeMs: 900)
        let to = words.sourceOffset(mediaTimeMs: 1_600)!
        XCTAssertTrue(Words.isContinuous(fromMs: 900, toMs: 1_600))
        for offset in words.rowsCrossed(fromOffset: from, toOffset: to) { state.move(offset: offset) }
        XCTAssertFalse(state.follow.isFollowing, "playback going on never pulls a reader back")
        XCTAssertEqual(state.litSentenceID, words.rows[2].id)

        // Without the crossed rows, the same tick would read as a jump.
        var naive = PlaybackNowSceneState(text: words.text, sentenceStarts: words.sentenceStarts, isNote: true)
        naive.move(offset: from!)
        naive.listenerScrolled()
        naive.move(offset: to)
        XCTAssertTrue(naive.follow.isFollowing)
    }

    func testASeekOrRewindIsNotContinuous() {
        XCTAssertFalse(Words.isContinuous(fromMs: nil, toMs: 1_000))
        XCTAssertFalse(Words.isContinuous(fromMs: 10_000, toMs: 9_000), "a move back")
        XCTAssertFalse(Words.isContinuous(fromMs: 10_000, toMs: 25_000), "a 15 s skip")
        XCTAssertFalse(Words.isContinuous(fromMs: 10_000, toMs: 14_001))
        XCTAssertTrue(Words.isContinuous(fromMs: 10_000, toMs: 14_000))
        XCTAssertTrue(Words.isContinuous(fromMs: 10_000, toMs: 10_000))
    }

    // MARK: taps and Margins

    func testRowStartMs() {
        let note = twoTakes()
        let words = Words(note: note, timeline: timeline(note))
        XCTAssertEqual(words.rows.map(\.startMs), [0, 4_000, 10_000, 15_000])
        XCTAssertEqual(words.row(id: words.rows[2].id)?.startMs, 10_000)
        XCTAssertNil(words.row(id: words.rows[2].id + 1))
        XCTAssertEqual(Words(note: note, timeline: nil).rows.map(\.startMs), [nil, nil, nil, nil])
        XCTAssertEqual(words.rowIdsWithAudio, Set(words.rows.map(\.id)))
        XCTAssertEqual(Words(note: note, timeline: nil).rowIdsWithAudio, [], "no timeline, nothing to play from")
    }

    func testMarginRowsFollowTheirSentenceById() {
        // A Margin on take b's first sentence, recorded when take a had no words: its character range is stale.
        let before = note([("a", 10_000, []), ("b", 10_000, [("Third thought.", 0, 2_000)])])
        let segment = SpokenNoteMargins.segmentId(takeId: "b", sentenceIndex: 0)
        let made = margin("m1", anchor: anchor(segmentId: segment, timeMs: 10_000, startChar: 0), at: 1)
        var after = before
        after.setTranscript([SpokenNoteSentence(text: "Words that arrived later.", startMs: 0, endMs: 2_000)], forTake: "a")
        let words = Words(note: after, timeline: timeline(after))
        let items = words.marginItems([made], itemId: itemId)
        XCTAssertEqual(items, [.init(afterRowId: words.rows[1].id, marginId: "m1", sessionId: "session")])
        XCTAssertNotEqual(words.rows[1].id, 0, "the stored range would have put it on the first sentence")

        // In a scene, the row stands right after its sentence.
        var state = PlaybackNowSceneState(text: words.text, sentenceStarts: words.sentenceStarts, isNote: true)
        state.move(offset: 0)
        state.setNoteMargins(items)
        let shape = state.shownItems.map { item -> String in
            switch item {
            case .sentence(let sentence): sentence.text
            case .clip(let floatId, _): "clip \(floatId)"
            case .margin(let item, _): "margin \(item.marginId)"
            }
        }
        XCTAssertEqual(shape, ["Words that arrived later.", "Third thought.", "margin m1"])
    }

    func testMarginsWithoutAPlaceOrRowGetNoItem() {
        let note = note([("a", 10_000, [("Late start.", 3_000, 5_000), ("Second.", 6_000, 8_000)])])
        let words = Words(note: note, timeline: timeline(note))
        let second = SpokenNoteMargins.segmentId(takeId: "a", sentenceIndex: 1)
        let list = [
            margin("no-place", anchor: anchor(segmentId: nil, timeMs: nil), at: 1),
            margin("before-first", anchor: anchor(segmentId: nil, timeMs: 1_000), at: 2),
            margin("deleted", anchor: anchor(segmentId: second, timeMs: 6_000), at: 3, status: "deleted"),
            margin("elsewhere", anchor: anchor(segmentId: second, timeMs: 6_000), at: 4, item: "another-item"),
            margin("reply", anchor: anchor(segmentId: second, timeMs: 6_000), at: 5, target: .summaryTurn),
            margin("late", anchor: anchor(segmentId: second, timeMs: 6_000), at: 9),
            margin("kept", anchor: anchor(segmentId: second, timeMs: 6_000), at: 6)
        ]
        XCTAssertEqual(words.marginItems(list, itemId: itemId).map(\.marginId), ["kept", "late"], "in the order made")
        XCTAssertEqual(Words(note: note, timeline: nil).marginItems(list, itemId: itemId), [], "no timeline, no rows")
    }

    func testMarginItemIdsNeverCollide() {
        let note = twoTakes()
        let words = Words(note: note, timeline: timeline(note))
        let first = SpokenNoteMargins.segmentId(takeId: "a", sentenceIndex: 0)
        let last = SpokenNoteMargins.segmentId(takeId: "b", sentenceIndex: 1)
        var state = PlaybackNowSceneState(text: words.text, sentenceStarts: words.sentenceStarts, isNote: true)
        state.move(offset: 0)
        let later = margin("later", anchor: anchor(segmentId: last, timeMs: 15_000), at: 2)
        state.setNoteMargins(words.marginItems([later], itemId: itemId))
        let laterId = state.shownItems.first { if case .margin = $0 { true } else { false } }?.id
        // An earlier Margin added afterwards keeps the later one's id.
        let earlier = margin("earlier", anchor: anchor(segmentId: first, timeMs: 0), at: 3)
        let revision = state.sceneRevision
        state.setNoteMargins(words.marginItems([later, earlier], itemId: itemId))
        XCTAssertGreaterThan(state.sceneRevision, revision)
        let ids = state.shownItems.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every row's id is its own")
        let marginIds = state.shownItems.compactMap { item -> (String, Int)? in
            if case .margin(let m, let id) = item { (m.marginId, id) } else { nil }
        }
        XCTAssertEqual(marginIds.first { $0.0 == "later" }?.1, laterId)
        XCTAssertTrue(marginIds.allSatisfy { $0.1 <= -1_000_000 })
        // The same list again changes nothing.
        let settled = state.sceneRevision
        state.setNoteMargins(words.marginItems([later, earlier], itemId: itemId))
        XCTAssertEqual(state.sceneRevision, settled)
    }

    // MARK: choices

    func testAvailability() {
        typealias A = SpokenNoteNowPassage.Availability
        XCTAssertEqual(A(note: nil), .noWords)
        XCTAssertEqual(A(note: SpokenNote(id: "empty")), .noWords)
        XCTAssertEqual(A(note: twoTakes()), .ready)
        XCTAssertEqual(A(note: note([("a", 1_000, [("Words.", 0, 500)]), ("b", 1_000, []), ("c", 1_000, [])])), .partial(takesWithoutWords: 2))
        XCTAssertEqual(A(note: note([("a", 1_000, []), ("b", 1_000, [])])), .noWords)
        XCTAssertEqual(A(note: note([("a", 1_000, [("  ", 0, 500)])])), .noWords, "only whitespace is no words")
        XCTAssertEqual(A(note: note([("a", 1_000, [("  ", 0, 500)]), ("b", 1_000, [("Hi.", 0, 500)])])), .partial(takesWithoutWords: 1))
    }

    func testNowLayoutChoice() {
        typealias L = SpokenNoteNowPassage.NowLayout
        let all: [SpokenNoteNowPassage.Availability] = [.loading, .ready, .partial(takesWithoutWords: 1), .noWords]
        for availability in all {
            // Not a note: the old flag decides, whatever the availability.
            XCTAssertEqual(L.choose(isNativeAudio: true, isSpokenNote: false, availability: availability), .audio)
            XCTAssertEqual(L.choose(isNativeAudio: false, isSpokenNote: false, availability: availability), .text)
            for nativeAudio in [true, false] {
                let expected: L = switch availability {
                case .ready, .partial: .noteWords
                case .noWords: .noteNoWords
                case .loading: .noteLoading
                }
                XCTAssertEqual(L.choose(isNativeAudio: nativeAudio, isSpokenNote: true, availability: availability), expected)
            }
        }
        XCTAssertEqual([L.audio, .text, .noteWords, .noteNoWords, .noteLoading].map(\.hasScene), [false, true, true, false, false])
    }

    func testRowTap() {
        typealias T = SpokenNoteNowPassage.RowTap
        XCTAssertEqual(T.rowTap(hasActiveSession: true, isSessionItem: true, targetIsSource: true, phase: .itemPlayback, hasAudio: true), .seeks)
        XCTAssertEqual(T.rowTap(hasActiveSession: true, isSessionItem: true, targetIsSource: true, phase: .finished, hasAudio: true), .inertFinished)
        XCTAssertEqual(T.rowTap(hasActiveSession: false, isSessionItem: true, targetIsSource: true, phase: .finished, hasAudio: true), .inertFinished)
        XCTAssertEqual(T.rowTap(hasActiveSession: true, isSessionItem: true, targetIsSource: false, phase: .summaryPlayback, hasAudio: true), .inert, "a Margin plays")
        XCTAssertEqual(T.rowTap(hasActiveSession: false, isSessionItem: true, targetIsSource: true, phase: .itemPlayback, hasAudio: true), .inert)
        XCTAssertEqual(T.rowTap(hasActiveSession: true, isSessionItem: false, targetIsSource: true, phase: .itemPlayback, hasAudio: true), .inert, "another item")
        XCTAssertEqual(T.rowTap(hasActiveSession: true, isSessionItem: false, targetIsSource: true, phase: .finished, hasAudio: true), .inert)
        XCTAssertEqual(T.rowTap(hasActiveSession: true, isSessionItem: true, targetIsSource: true, phase: .itemPlayback, hasAudio: false), .inert)
    }

    func testNoteEndLine() {
        XCTAssertEqual(PlaybackNowSceneState(text: "Hi.", isNote: true).endLine.heading, "End of the note")
        XCTAssertEqual(PlaybackNowSceneState(text: "Hi.").endLine.heading, "End of the text")
    }
}
