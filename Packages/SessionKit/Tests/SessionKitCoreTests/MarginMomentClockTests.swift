import Foundation
import XCTest
@testable import SessionKit

/// #1577: "Play this moment" on a Margin anchored by text position, in an article read aloud on the device.
///
/// The owner's phone showed no countdown and no Margin voice, only the source from text anchor 1214, because the
/// moment needed a media time that such a Margin never has. These pin the host-side half: the narration clock,
/// the one 30-second lead-in rule on it, and which Margins a moment plays.
final class MarginMomentClockTests: XCTestCase {
    private let clock = MarginMomentClock.liveNarration

    // MARK: The clock

    func testNarrationTimeIsTextOffsetOverTheTypicalReadingRate() {
        XCTAssertEqual(ListeningTimeEstimator.defaultCharactersPerSecond, 14)
        XCTAssertEqual(clock.position(forTextOffset: 0), 0)
        XCTAssertEqual(clock.position(forTextOffset: 14), 1_000)
        XCTAssertEqual(clock.position(forTextOffset: 420), 30_000)
        XCTAssertEqual(clock.position(forTextOffset: -5), 0, "a negative offset clamps to the start")
    }

    func testTextOffsetsSurviveTheRoundTripExactly() {
        // The conductor seeks to the Margin by its place on the clock, so a one-character drift would land
        // beside the Margin, not on it.
        for offset in [0, 1, 7, 13, 14, 15, 99, 1_214, 5_001, 123_457] {
            XCTAssertEqual(clock.textOffset(forPosition: clock.position(forTextOffset: offset)), offset, "offset \(offset)")
        }
        let slow = MarginMomentClock.narratedText(charactersPerSecond: 9.5)
        for offset in [1, 333, 1_214, 80_000] {
            XCTAssertEqual(slow.textOffset(forPosition: slow.position(forTextOffset: offset)), offset, "slow offset \(offset)")
        }
    }

    func testAMediaClockHasNoTextOffsetsAndAnImplausibleRateFallsBackToTheTypicalOne() {
        XCTAssertEqual(MarginMomentClock.media.position(forTextOffset: 500), 0)
        XCTAssertEqual(MarginMomentClock.media.textOffset(forPosition: 5_000), 0)
        for rate in [0.0, -3.0, .nan, .infinity] {
            let odd = MarginMomentClock.narratedText(charactersPerSecond: rate)
            XCTAssertEqual(odd.position(forTextOffset: 140), 10_000, "rate \(rate)")
        }
    }

    func testOnlyATextClockTicksBySentences() {
        XCTAssertEqual(MarginMomentClock.media.tickAdvanceLimitMs, MarginMomentSequence.maxTickAdvanceMs)
        XCTAssertGreaterThan(clock.tickAdvanceLimitMs, 30_000, "a long sentence, about 400 characters, is one tick")
    }

    // MARK: The lead-in rule on the narration clock

    func testTheLeadInIsThirtySecondsOfNarrationBeforeTheTextAnchor() {
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 1_214))
        let sequence = MarginMomentSequence(
            itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)

        // Through the single rule (#807), not a second copy of the length.
        let rule = ListeningMoment(
            use: .playThisMoment, margin: .init(id: target.marginId, position: target.mediaTimeMs), source: .media())
        XCTAssertEqual(sequence.startMediaTimeMs, rule.sourceStartPosition)
        XCTAssertEqual(target.mediaTimeMs - sequence.startMediaTimeMs, 30_000)
        XCTAssertEqual(clock.textOffset(forPosition: sequence.startMediaTimeMs), 1_214 - 420)

        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: nil), "0:30", "the card counts from the whole lead-in")
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: clock.position(forTextOffset: 1_214 - 420)), "0:30")
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: clock.position(forTextOffset: 1_214 - 140)), "0:10")
        XCTAssertNil(sequence.targetCountdown(currentMediaTimeMs: clock.position(forTextOffset: 1_300)), "past the Margin")
    }

    func testAMarginInTheFirstThirtySecondsOfTextLeadsInFromTheStart() {
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 70))
        let sequence = MarginMomentSequence(itemId: "article", target: target, otherMargins: [])
        XCTAssertEqual(sequence.startMediaTimeMs, 0)
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: nil), "0:05")
    }

    /// Sentence-sized progress readings, as on-device speech gives them, play the Margin when reading reaches it. The
    /// media clock's half-second limit read every one of them as a skip, so the Margin never played.
    func testSentenceSizedReadingsReachTheMarginOnTheNarrationClockButNotTheMediaLimit() {
        let sentenceStarts = Array(stride(from: 794, through: 1_334, by: 90)) // 794, 884, ..., 1_334
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 1_214))

        func play(limit: Int) -> MarginMomentAnchor? {
            var sequence = MarginMomentSequence(
                itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: limit)
            for (before, after) in zip(sentenceStarts, sentenceStarts.dropFirst()) {
                if let played = sequence.progressed(
                    from: clock.position(forTextOffset: before), to: clock.position(forTextOffset: after)
                ) { return played }
            }
            return nil
        }

        XCTAssertEqual(play(limit: clock.tickAdvanceLimitMs), target)
        XCTAssertNil(play(limit: MarginMomentSequence.maxTickAdvanceMs), "why a text clock needs its own limit")
    }

    func testAForwardJumpLongerThanASentenceIsASkipAndDoesNotPlayTheMargin() {
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 3_000))
        var sequence = MarginMomentSequence(
            itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
        XCTAssertNil(sequence.progressed(
            from: clock.position(forTextOffset: 2_000), to: clock.position(forTextOffset: 4_000)))
    }

    // MARK: Which Margins play

    private func margin(
        _ id: String, session: String = "s", mediaTimeMs: Int? = nil, startChar: Int = 0,
        audio: String? = "margin.m4a", kind: InterjectionCaptureKind? = nil, status: String = "active",
        targetType: InterjectionTargetType = .item
    ) -> Interjection {
        Interjection(
            id: id, itemId: "article", sessionId: session, targetType: targetType, targetId: "article",
            createdAt: Date(timeIntervalSince1970: 0), roughPercent: 0,
            anchor: Anchor(
                anchorType: mediaTimeMs == nil ? .text : .transcript, startChar: startChar, endChar: startChar + 10,
                anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
            audioPath: audio, audioStatus: "recorded", transcriptionStatus: "pending", transcript: nil,
            cleanedTranscript: nil, displayText: nil, status: status, captureKind: kind)
    }

    func testATextAnchoredSpokenMarginIsASpokenItemMarginButNotAnInlineOne() {
        let text = margin("ij-1", startChar: 1_214)
        XCTAssertTrue(text.isSpokenItemMargin, "it has a voice and a place in the article")
        XCTAssertFalse(text.isInlineSpokenMargin, "no media time, which was the early return behind #1577")
        XCTAssertTrue(margin("ij-2", mediaTimeMs: 60_000).isInlineSpokenMargin)
        XCTAssertFalse(margin("w", kind: .written).isSpokenItemMargin)
        XCTAssertFalse(margin("n", audio: nil).isSpokenItemMargin, "no recording")
        XCTAssertFalse(margin("d", status: "deleted").isSpokenItemMargin)
        XCTAssertFalse(margin("t", targetType: .assistantTurn).isSpokenItemMargin, "a reply is not on the item")
    }

    func testOnTheNarrationClockEveryMarginIsPlacedByItsTextOffset() throws {
        let played = margin("ij-2", startChar: 1_214)
        let earlier = margin("ij-1", startChar: 700)
        let later = margin("ij-3", session: "s2", startChar: 2_800)
        let written = margin("ij-4", startChar: 1_500, kind: .written)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: played, among: [earlier, played, later, written], clock: clock, targetMediaTimeMs: nil))
        XCTAssertEqual(anchors.target, MarginMomentAnchor(marginId: "s::ij-2", mediaTimeMs: 86_714))
        XCTAssertEqual(anchors.others.map(\.marginId), ["s::ij-1", "s2::ij-3"], "the chosen Margin is not its own follower")
        XCTAssertEqual(anchors.others.map(\.mediaTimeMs), [50_000, 200_000])
    }

    func testAMarginsMomentIdentityIsItsSessionAndId() {
        XCTAssertEqual(MarginMomentPlanner.identity(margin("ij-7", session: "s9")), "s9::ij-7")
    }

    func testTheSameMarginIdInAnotherSessionIsAnotherMargin() throws {
        let played = margin("ij-1", session: "s", startChar: 1_000)
        let namesake = margin("ij-1", session: "s2", startChar: 2_000)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: played, among: [played, namesake], clock: clock, targetMediaTimeMs: nil))
        XCTAssertEqual(anchors.others.map(\.marginId), ["s2::ij-1"])
    }

    func testOnAMediaClockATextOnlyMarginTakesWhereTheSourceStandsAndItsOwnMediaTimeWins() throws {
        let textOnly = margin("ij-1", startChar: 1_214)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: textOnly, among: [textOnly], clock: .media, targetMediaTimeMs: 88_000))
        XCTAssertEqual(anchors.target.mediaTimeMs, 88_000, "an article's prepared narration found the place on its timeline")

        let timed = margin("ij-2", mediaTimeMs: 120_000, startChar: 1_214)
        let own = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: timed, among: [timed], clock: .media, targetMediaTimeMs: 88_000))
        XCTAssertEqual(own.target.mediaTimeMs, 120_000)
        XCTAssertNil(MarginMomentPlanner.anchors(played: textOnly, among: [], clock: .media, targetMediaTimeMs: nil),
                     "no media time anywhere: nothing to count on")
    }

    func testOnAMediaClockOtherMarginsNeedAMediaTimeOfTheirOwn() throws {
        let played = margin("ij-1", mediaTimeMs: 120_000)
        let timed = margin("ij-2", mediaTimeMs: 200_000)
        let textOnly = margin("ij-3", startChar: 5_000)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: played, among: [played, timed, textOnly], clock: .media, targetMediaTimeMs: 120_000))
        XCTAssertEqual(anchors.others.map(\.marginId), ["s::ij-2"])
    }

    func testAWrittenMarginHasNoMoment() {
        let written = margin("ij-1", startChar: 100, kind: .written)
        XCTAssertNil(MarginMomentPlanner.anchors(played: written, among: [written], clock: clock, targetMediaTimeMs: nil))
    }

    // MARK: Starting the lead-in on a sentence

    func testTheLeadInStartsAtTheNextSentenceStart() {
        let text = "One two three. Four five six. Seven eight nine. Ten eleven twelve."
        // "Four" starts at 15, "Seven" at 30, "Ten" at 48.
        let table: [(offset: Int, limit: Int, expected: Int, note: String)] = [
            (0, 66, 0, "the start"),
            (15, 66, 15, "already at a sentence start"),
            (16, 66, 30, "inside a sentence: on to the next one"),
            (29, 66, 30, "just before a start, in the space"),
            (30, 66, 30, "exactly at a start"),
            (31, 40, 31, "the next start is past the Margin: stay"),
            (31, 48, 31, "the next start is the Margin itself: stay"),
            (31, 49, 48, "the next start is just before the Margin"),
            (60, 66, 60, "the last sentence has no start after it"),
        ]
        for row in table {
            XCTAssertEqual(
                MarginMomentClock.sentenceStart(atOrAfter: row.offset, before: row.limit, in: text), row.expected, row.note)
        }
    }

    func testSentenceStartsNeighbouringInputs() {
        // Decimals, abbreviations written with no space, and other punctuation are not sentence ends.
        let numbers = "It cost 3.5 million. Then it rose."
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 10, before: 34, in: numbers), 21)
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 5, before: 34, in: "He said hi! And left? Yes."), 12)
        // Several spaces, a line break and a tab all count as the gap after a sentence.
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 2, before: 30, in: "Hi.   There.\nHere."), 6)
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 8, before: 30, in: "Hi.   There.\nHere."), 13)
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 2, before: 30, in: "Hi.\tThere."), 4)
        // Offsets count Characters, as `String.count` does for the item's text: an emoji or an accent is one.
        let accented = "Café 👩🏽‍💻 fini. Après le café. Encore."
        let start = Array(accented).firstIndex(of: "A")!
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 3, before: accented.count, in: accented), start)
        // Nothing to find.
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 5, before: 10, in: ""), 5)
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 5, before: 100, in: "No stops at all in this text"), 5)
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 5, before: 100, in: "Ends here."), 5)
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: -4, before: 100, in: "A. B."), 0)
    }

    func testSentenceStartOnAVeryLongText() {
        let sentence = "Words go here and there. "
        let text = String(repeating: sentence, count: 20_000)
        let offset = 250_007
        let expected = (offset / sentence.count + 1) * sentence.count
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: offset, before: text.count, in: text), expected)
    }
}
