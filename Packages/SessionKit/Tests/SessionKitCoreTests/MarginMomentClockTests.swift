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

    func testATextClockHasARoomierLimitThanAMediaClockButAShortOneAllTheSame() {
        XCTAssertEqual(MarginMomentClock.media.tickAdvanceLimitMs, MarginMomentSequence.maxTickAdvanceMs)
        // Word-by-word speech reports a few characters a tick, so the text limit only has to cover a late tick; a
        // longer one would take a sentence skip over a Margin for playback (#1646).
        XCTAssertGreaterThan(clock.tickAdvanceLimitMs, MarginMomentSequence.maxTickAdvanceMs)
        XCTAssertLessThanOrEqual(clock.tickAdvanceLimitMs, 6_000)
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

    /// Progress readings from on-device speech, a word or a few words a tick, reach the Margin on the narration
    /// clock. The media clock's 4 s limit is 56 characters at this rate, so the text clock needs a limit of its own.
    func testWordSizedReadingsReachTheMarginOnTheNarrationClock() {
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 1_214))
        for step in [7, 14, 30, 60] { // half a second at 1x, a second, 2x to 3x speech, and a late tick
            var sequence = MarginMomentSequence(
                itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
            var played: MarginMomentAnchor?
            for before in stride(from: 1_100, to: 1_300, by: step) where played == nil {
                played = sequence.progressed(
                    from: clock.position(forTextOffset: before), to: clock.position(forTextOffset: before + step))
            }
            XCTAssertEqual(played, target, "readings \(step) characters apart")
        }
    }

    /// Skipping forward by a sentence or two (over a hundred characters) past the next Margin must not play it
    /// (#1646): "skipping over a Margin shouldn't play it", as on a podcast.
    func testSkippingForwardBySentencesOverAMarginDoesNotPlayIt() {
        let played = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 1_214))
        let next = MarginMomentAnchor(marginId: "s::ij-2", mediaTimeMs: clock.position(forTextOffset: 1_300))
        for (from, to) in [(1_250, 1_380), (1_240, 1_400), (1_290, 1_450)] { // 130 to 160 characters
            var sequence = MarginMomentSequence(
                itemId: "article", resumingAtMediaTimeMs: clock.position(forTextOffset: from), playedMargin: played,
                otherMargins: [next], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
            XCTAssertNil(
                sequence.progressed(from: clock.position(forTextOffset: from), to: clock.position(forTextOffset: to)),
                "a skip from \(from) to \(to)")
            XCTAssertEqual(sequence.unplayed, [next], "the skipped-over Margin still waits, from \(from)")
        }
    }

    /// A reading at the Margin's own place right after the lead-in starts (a stale reading from the speech client, or a
    /// 30-second skip) is not playback reaching it.
    func testAReadingThatJumpsTheWholeLeadInDoesNotPlayTheMargin() {
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 1_214))
        var sequence = MarginMomentSequence(
            itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
        XCTAssertNil(sequence.progressed(from: sequence.startMediaTimeMs, to: target.mediaTimeMs))
    }

    func testAForwardJumpLongerThanASentenceIsASkipAndDoesNotPlayTheMargin() {
        let target = MarginMomentAnchor(marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: 3_000))
        var sequence = MarginMomentSequence(
            itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
        XCTAssertNil(sequence.progressed(
            from: clock.position(forTextOffset: 2_000), to: clock.position(forTextOffset: 4_000)))
    }

    /// #1656: neighbouring jump sizes, with a Margin in the jumped-over text. Up to the limit (84 characters, six
    /// seconds of narration) a reading is playback and reaches the Margin; anything longer, and any backward move, is not.
    func testJumpSizesOnTheNarrationClockSeparateReadingFromSkipping() {
        let rows: [(size: Int, plays: Bool)] = [
            (7, true), (30, true), (60, true), (84, true), // word-sized and a late tick, up to the limit
            (85, false), (100, false), (200, false), (350, false), (3_000, false) // a skip, a scrub, a chapter jump
        ]
        let from = 1_120
        for row in rows {
            let target = MarginMomentAnchor(
                marginId: "s::ij-1", mediaTimeMs: clock.position(forTextOffset: from + row.size / 2))
            var sequence = MarginMomentSequence(
                itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
            let played = sequence.progressed(
                from: clock.position(forTextOffset: from), to: clock.position(forTextOffset: from + row.size))
            XCTAssertEqual(played != nil, row.plays, "forward by \(row.size) characters over a Margin")
            var backward = MarginMomentSequence(
                itemId: "article", target: target, otherMargins: [], tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
            XCTAssertNil(
                backward.progressed(
                    from: clock.position(forTextOffset: from + row.size), to: clock.position(forTextOffset: from)),
                "back by \(row.size) characters over a Margin")
        }
    }

    /// #1656: a command from the Lock Screen, headphones, the Watch or CarPlay that moves the source is one the Margin
    /// moment is told about, so it can't count as reading either.
    func testEveryCompactCommandThatMovesTheSourceIsNamed() {
        let moving: Set<CompactControlCommand> = [
            .skipBack, .skipForward, .skimBackward, .skimForward, .seekToMediaTime, .jumpToChapter
        ]
        for command in CompactControlCommand.allCases {
            XCTAssertEqual(command.movesPlaybackPosition, moving.contains(command), command.rawValue)
        }
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
        let earlier = margin("ij-1", startChar: 910)
        let later = margin("ij-3", session: "s2", startChar: 2_800)
        let written = margin("ij-4", startChar: 1_500, kind: .written)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: played, among: [earlier, played, later, written], clock: clock, targetMediaTimeMs: nil))
        XCTAssertEqual(anchors.target, MarginMomentAnchor(marginId: "s::ij-2", mediaTimeMs: 86_714))
        XCTAssertEqual(anchors.others.map(\.marginId), ["s::ij-1", "s2::ij-3"], "the chosen Margin is not its own follower")
        XCTAssertEqual(anchors.others.map(\.mediaTimeMs), [65_000, 200_000])
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

    /// The lead-in starts on a sentence (#1646): a Margin in the stretch before that start is not part of the moment,
    /// or reading never crosses it and the card stays until Stop.
    func testAMarginBeforeTheSnappedLeadInStartIsNotPartOfTheMoment() throws {
        let text = String(repeating: "Words go here and there. ", count: 80) // a sentence starts every 25 characters
        let played = margin("ij-played", startChar: 1_214)
        // The lead-in would start at 794; the first sentence start after it is 800.
        let inTheGap = margin("ij-gap", startChar: 796)
        let atTheStart = margin("ij-start", startChar: 800)
        let before = margin("ij-before", startChar: 700)
        let after = margin("ij-after", startChar: 1_500)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: played, among: [before, inTheGap, atTheStart, played, after], clock: clock,
            targetMediaTimeMs: nil, text: text))
        XCTAssertEqual(anchors.others.map(\.marginId), ["s::ij-start", "s::ij-after"])
        XCTAssertEqual(clock.leadInStartOffset(forTargetPosition: anchors.target.mediaTimeMs, in: text), 800)

        // Reading from the snapped start through the end of the moment: the card ends after the last Margin.
        var sequence = MarginMomentSequence(
            itemId: "article", target: anchors.target, otherMargins: anchors.others,
            tickAdvanceLimitMs: clock.tickAdvanceLimitMs)
        var heard: [String] = []
        for before in stride(from: 800, to: 1_600, by: 14) {
            if let reached = sequence.progressed(
                from: clock.position(forTextOffset: before), to: clock.position(forTextOffset: before + 14)) {
                heard.append(reached.marginId)
                sequence.marginFinished()
            }
        }
        XCTAssertEqual(heard, ["s::ij-start", "s::ij-played", "s::ij-after"])
        XCTAssertTrue(sequence.unplayed.isEmpty, "the card goes away once the last Margin has played")
    }

    func testWithNoTextTheMomentKeepsTheMarginsTheUnsnappedLeadInWouldPlay() throws {
        let played = margin("ij-played", startChar: 1_214)
        let inTheGap = margin("ij-gap", startChar: 796)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: played, among: [inTheGap], clock: clock, targetMediaTimeMs: nil))
        XCTAssertEqual(anchors.others.map(\.marginId), ["s::ij-gap"], "no sentence to snap to: the lead-in starts at 794")
        XCTAssertEqual(clock.leadInStartOffset(forTargetPosition: anchors.target.mediaTimeMs, in: ""), 794)
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

    /// #1646: neighbouring inputs. Each row starts looking at offset 1 (inside the first sentence) and names the word
    /// the lead-in should start on.
    func testSentenceStartsAcrossQuotesBracketsAbbreviationsEllipsesAndBreaks() throws {
        let rows: [(text: String, starts: String, note: String)] = [
            ("He said \"Go.\" Then left. Done.", "Then", "a closing quote after the full stop"),
            ("He said \u{201C}Go.\u{201D} Then left. Done.", "Then", "closing curly quotes"),
            ("She left (quietly.) Then he did. Done.", "Then", "a closing bracket"),
            ("He asked \"Why?\" She left. Done.", "She", "a question mark inside a quote"),
            ("Really?! Yes it was. Fine.", "Yes", "two marks in a row"),
            ("Mr. Smith left. Then Dr. Jones arrived.", "Then", "titles are not sentence ends"),
            ("See e.g. the notes. Then more.", "Then", "e.g. is not a sentence end"),
            ("That is, i.e. the end. Then more.", "Then", "i.e. is not a sentence end"),
            ("J. K. Rowling wrote it. Then more.", "Then", "initials"),
            ("It starts at 5 p.m. today. Next one.", "Next", "an abbreviation before a lower-case word"),
            ("Wait... then he left. Next one.", "Next", "an ellipsis inside a sentence"),
            ("Wait\u{2026} then he left. Next one.", "Next", "an ellipsis character inside a sentence"),
            ("Wait... Then he left. Next one.", "Then", "an ellipsis before a capital ends the sentence"),
            ("\"Why?\" he asked. Then more. Done.", "Then", "dialogue: a lower-case word after the quote"),
            ("\"Stop!\" she said. Then more. Done.", "Then", "an exclamation in a quote"),
            ("\u{201C}Why?\u{201D} he asked. Then more.", "Then", "curly quotes"),
            ("He said so and so did I. Then they left. Done.", "Then", "the pronoun I ends a sentence"),
            ("It was Plan B or C. Then they left. Done.", "Then", "a capital after a lower-case word ends a sentence"),
            ("See Fig. 3 for it. Then more.", "Then", "a figure number"),
            ("It was No. 5 on the list. Then more.", "Then", "a numbered title"),
            ("I said no. Then we left. Done.", "Then", "no, not a number"),
            ("Chapter One\n\nIt began here. Later.", "It began", "a heading with no punctuation"),
            ("Heading\r\n\r\nBody here. More.", "Body", "a heading before Windows line breaks"),
            ("Hello.\nWorld here. End.", "World", "a single line break after a full stop"),
            ("First line\n  \nSecond block. End.", "Second", "a blank line with spaces in it"),
            // #1656: initials, initialisms, abbreviations and brands that end a sentence or don't.
            ("Take Vitamin A. Then rest. Done.", "Then", "a single capital closing a sentence, before an opener"),
            ("Take Vitamin A. Rest well. Done.", "Done", "known limit: a word that could be a surname after a single capital reads as a name, so the lead-in starts a sentence later, never mid-sentence"),
            ("George R. R. Martin wrote it. Then more.", "Then", "two initials in a name"),
            ("Franklin D. Roosevelt spoke. Then more.", "Then", "a middle initial after a capitalised name"),
            ("Turn left on Main St. Then stop. Done.", "Then", "St. closing a sentence, before an opener"),
            ("He went to St. Louis today. Then more.", "Then", "St. in a place name"),
            ("It was Martin Luther King Jr. Then more.", "Then", "Jr. closing a sentence"),
            ("Ask Acme Inc. Then wait. Done.", "Then", "Inc. closing a sentence"),
            ("Ask Acme Inc. Smith will help. Done.", "Done", "Inc. before a name"),
            ("She said no. 5 people came anyway. Done.", "5 people", "the word no, not No."),
            ("It was No. 5 on the list. Then more.", "Then", "No. before a number"),
            ("It was NO. 5 on the list. Then more.", "Then", "NO. before a number"),
            ("Read vol. 3 first. Then more.", "Then", "vol. before a number in lower case"),
            ("He ordered the U.S. Army to stand down. Then more.", "Then", "an initialism before a name"),
            ("He lived in the U.S. Then he left. Done.", "Then", "an initialism closing a sentence"),
            ("It is in Washington, D.C. Then more.", "Then", "D.C. closing a sentence"),
            ("We tried it. iPhone sales rose. Done.", "iPhone", "a brand with a lower-case first letter"),
            ("We tried it. eBay sales rose. Done.", "eBay", "another such brand"),
            ("Levels fell... mRNA counts rose. Done.", "Done", "a brand after an ellipsis: only a pause"),
            ("Levels fell... pH rose. Done.", "Done", "another such word after an ellipsis"),
            ("We tried it. then it broke. Done.", "Done", "an ordinary lower-case word carries the sentence on"),
        ]
        for row in rows {
            let expected = try XCTUnwrap(row.text.range(of: row.starts)).lowerBound
            XCTAssertEqual(
                MarginMomentClock.sentenceStart(atOrAfter: 1, before: row.text.count, in: row.text),
                row.text.distance(from: row.text.startIndex, to: expected), row.note)
        }
    }

    func testASingleLineBreakInsideASentenceIsNotAStart() {
        let wrapped = "A sentence that was wrapped\nonto a second line. Then another."
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: 1, before: wrapped.count, in: wrapped), 48)
    }

    func testSentenceStartOnAVeryLongText() {
        let sentence = "Words go here and there. "
        let text = String(repeating: sentence, count: 20_000)
        let offset = 250_007
        let expected = (offset / sentence.count + 1) * sentence.count
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: offset, before: text.count, in: text), expected)
    }

    // MARK: Reading only the window around the Margin (#2506)

    /// The scan the lead-in used before it read a window: the whole text as an array, from the first character.
    private func scanFromTheStart(atOrAfter offset: Int, before limit: Int, in text: String) -> Int {
        guard offset > 0 else { return 0 }
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if let start = MarginMomentClock.nextSentenceStart(in: characters, at: &index), start >= offset {
                return start < limit ? start : offset
            }
        }
        return offset
    }

    func testWindowedSentenceStartMatchesAScanFromTheStart() {
        // Fragments that exercise the stop rules, repeated in a fixed but irregular order, so every offset lands
        // somewhere different in a sentence, an abbreviation, a quote, a break or an accent.
        let fragments = [
            "Words go here and there.", "He met Dr. Smith at 3.5 percent.", "\"Why?\" he asked.", "Levels fell... mRNA rose.",
            "It is in Washington, D.C. Then more.", "Fig. 3 shows it!", "Café 👩🏽‍💻 fini.", "A heading\n\nwith no stop",
            "Vitamin A. Then rest.", "wrapped\nline goes on."
        ]
        var text = ""
        var step = 7
        while text.count < 6_000 {
            step = (step * 31 + 11) % 97
            text += fragments[step % fragments.count] + (step % 5 == 0 ? "   " : " ")
        }
        let count = text.count
        for offset in stride(from: 1, to: count, by: 37) {
            for reach in [3, 40, 420, 2_500] {
                let limit = min(count, offset + reach)
                XCTAssertEqual(
                    MarginMomentClock.sentenceStart(atOrAfter: offset, before: limit, in: text),
                    scanFromTheStart(atOrAfter: offset, before: limit, in: text),
                    "offset \(offset), limit \(limit)")
            }
        }
    }

    func testASentenceStartAfterABlankLineAndALongRunOfSpacesIsFound() {
        // The window opens 256 characters before the Margin, inside the padding, so it must reach back to the blank line.
        let text = "Heading\n\n" + String(repeating: " ", count: 300) + "Text goes on here and on."
        let paragraphStart = text.count - "Text goes on here and on.".count
        for offset in [paragraphStart - 280, paragraphStart - 100, paragraphStart - 2] {
            let limit = min(text.count, offset + 420)
            XCTAssertEqual(
                MarginMomentClock.sentenceStart(atOrAfter: offset, before: limit, in: text),
                scanFromTheStart(atOrAfter: offset, before: limit, in: text),
                "offset \(offset)")
        }
        XCTAssertEqual(MarginMomentClock.sentenceStart(atOrAfter: paragraphStart - 100, before: text.count, in: text), paragraphStart)
    }

    func testASentenceStartReadsAWindowNotTheWholeText() {
        let sentence = "Words go here and there. "
        let text = String(repeating: sentence, count: 80_000) // 2,000,000 characters
        let offset = 1_000_007
        let scan = MarginMomentClock.sentenceStartScan(atOrAfter: offset, before: offset + 420, in: text)
        XCTAssertEqual(scan.start, (offset / sentence.count + 1) * sentence.count)
        XCTAssertLessThan(scan.charactersRead, 5_000, "the lead-in's sentence start should not turn the article into an array")
        // A stretch with no stop at all grows the window until the Margin, and still agrees with the full scan.
        let unbroken = String(repeating: "word ", count: 4_000)
        let long = MarginMomentClock.sentenceStartScan(atOrAfter: 5_000, before: 15_000, in: unbroken)
        XCTAssertEqual(long.start, 5_000)
        XCTAssertLessThan(long.charactersRead, 40_000)
    }
}
