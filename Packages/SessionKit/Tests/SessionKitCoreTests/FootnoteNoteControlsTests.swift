import Foundation
import XCTest
@testable import SessionKit

/// #3777: the rules the player's controls and the Footnote card share, pinned on hand-written tag rows and then on
/// plans the real planner makes, so a change to the planner's chunks cannot leave these rules answering for a shape
/// the planner no longer produces.
final class FootnoteNoteControlsTests: XCTestCase {
    private typealias Tag = NarrationChunkPlanner.FootnoteTag
    private typealias Controls = FootnoteNoteControls

    // body, aside 1, body, aside 2 (two chunks), body, aside 3 and aside 4 at one citation, body, definitions
    private let tags: [Tag?] = [
        nil, .aside("1"), nil, .aside("2"), .aside("2"), nil, .aside("3"), .aside("a"), nil, .definition("1"), .definition("2")
    ]

    // MARK: - ¶› during a note

    func testParagraphForwardLeavesANoteForTheNextChunkOfTheMainText() {
        XCTAssertEqual(Controls.paragraphForward(from: 1, tags: tags), .continueAt(2))
        XCTAssertEqual(Controls.paragraphForward(from: 3, tags: tags), .continueAt(5), "the second chunk of a long note too")
        XCTAssertEqual(Controls.paragraphForward(from: 4, tags: tags), .continueAt(5))
    }

    func testParagraphForwardLeavesTheWholeRunOfNotesAtOneCitation() {
        XCTAssertEqual(Controls.paragraphForward(from: 6, tags: tags), .continueAt(8))
        XCTAssertEqual(Controls.paragraphForward(from: 7, tags: tags), .continueAt(8))
    }

    func testParagraphForwardOnABodyOrDefinitionChunkIsNotOurs() {
        for index in [0, 2, 5, 8, 9, 10, -1, 11, 99] {
            XCTAssertEqual(Controls.paragraphForward(from: index, tags: tags), .notOnANote, "\(index)")
        }
        XCTAssertEqual(Controls.paragraphForward(from: 0, tags: []), .notOnANote)
    }

    func testParagraphForwardFromTheLastNoteOfTheTextEndsTheText() {
        XCTAssertEqual(Controls.paragraphForward(from: 2, tags: [nil, nil, .aside("1")]), .endOfText)
        XCTAssertEqual(Controls.paragraphForward(from: 1, tags: [nil, .aside("1"), .aside("2")]), .endOfText)
    }

    // MARK: - Where a position saved during a note belongs

    func testAPositionDuringANoteBelongsToTheChunkBeforeItsFirstAside() {
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 1, tags: tags), 0)
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 3, tags: tags), 2)
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 4, tags: tags), 2, "the second chunk of a long note replays from the sentence, not the note's start")
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 6, tags: tags), 5)
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 7, tags: tags), 5, "the second note at one citation")
    }

    func testAChunkThatIsNotANoteAnswersItself() {
        for index in [0, 2, 5, 8, 9, 10] {
            XCTAssertEqual(Controls.resumeIndex(forChunkAt: index, tags: tags), index, "\(index)")
        }
    }

    func testANoteBeforeAnyBodyChunkAnswersTheFirstChunkAfterIt() {
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 0, tags: [.aside("1"), .aside("2"), nil, nil]), 2)
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 1, tags: [.aside("1"), .aside("2"), nil, nil]), 2)
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: 0, tags: [.aside("1")]), 0, "nothing else to go to")
    }

    func testAnIndexOutsideThePlanHasNoResumeChunk() {
        XCTAssertNil(Controls.resumeIndex(forChunkAt: -1, tags: tags))
        XCTAssertNil(Controls.resumeIndex(forChunkAt: tags.count, tags: tags))
        XCTAssertNil(Controls.resumeIndex(forChunkAt: 0, tags: []))
    }

    // MARK: - Where a resume during a note starts

    func testAResumeDuringANoteStartsAtTheCitingSentencesLastChunk() {
        // Offsets of the same plan shape as `tags`: an aside starts where the body chunk after it starts.
        let offsets = [0, 40, 40, 90, 90, 130, 160, 160, 200, 260, 300]
        let held = { Controls.heldStartOffset(forChunkAt: $0, tags: self.tags, startOffsets: offsets) }
        XCTAssertEqual(held(1), 0)
        XCTAssertEqual(held(3), 40)
        XCTAssertEqual(held(4), 40, "the second chunk of a long note resumes at the sentence too")
        XCTAssertEqual(held(6), 130)
        XCTAssertEqual(held(7), 130, "the second note at one citation")
    }

    func testOutsideANoteAResumeKeepsItsOwnOffset() {
        let offsets = [0, 40, 40, 90, 90, 130, 160, 160, 200, 260, 300]
        for index in [0, 2, 5, 8, 9, 10, -1, 11, 99] {
            XCTAssertNil(Controls.heldStartOffset(forChunkAt: index, tags: tags, startOffsets: offsets), "\(index)")
        }
        XCTAssertNil(Controls.heldStartOffset(forChunkAt: 1, tags: tags, startOffsets: [0, 1]), "offsets that do not line up with the plan")
    }

    func testANoteBeforeAnyBodyChunkResumesAtTheFirstChunkAfterIt() {
        XCTAssertEqual(Controls.heldStartOffset(forChunkAt: 0, tags: [.aside("1"), nil], startOffsets: [0, 0]), 0)
        XCTAssertEqual(Controls.heldStartOffset(forChunkAt: 1, tags: [.aside("1"), .aside("2"), nil], startOffsets: [5, 5, 5]), 5)
    }

    // MARK: - A fresh start where a note is cited (relaunch)

    func testAFreshStartAtAPlaceWhereANoteIsCitedStartsAtTheCitingSentence() {
        let offsets = [0, 40, 40, 90, 90, 130, 160, 160, 200, 260, 300]
        let restored = { Controls.restoredStartOffset(atOffset: $0, tags: self.tags, startOffsets: offsets) }
        XCTAssertEqual(restored(40), 0, "the note after the first sentence")
        XCTAssertEqual(restored(90), 40, "a note the planner split into two chunks")
        XCTAssertEqual(restored(160), 130, "two notes cited in one sentence")
    }

    func testAFreshStartAnywhereElseKeepsItsOffset() {
        let offsets = [0, 40, 40, 90, 90, 130, 160, 160, 200, 260, 300]
        // Every offset that is not a citation's place, including one a character either side of it and the plan's ends.
        for requested in [0, 1, 39, 41, 89, 91, 129, 130, 131, 159, 161, 199, 200, 260, 300, 301, -5] {
            XCTAssertEqual(Controls.restoredStartOffset(atOffset: requested, tags: tags, startOffsets: offsets), requested,
                           "\(requested)")
        }
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 40, tags: tags, startOffsets: [0, 40]), 40,
                       "offsets that do not line up with the plan")
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 40, tags: [], startOffsets: []), 40)
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 40, tags: [nil, nil], startOffsets: [0, 40]), 40, "no note")
    }

    func testAFreshStartDoesNotReplayANoteTheListenerAlreadyHeard() {
        let offsets = [0, 40, 40, 90, 90, 130, 160, 160, 200, 260, 300]
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 40, tags: tags, startOffsets: offsets, isHeard: { $0 == "1" }), 40,
                       "the same offset is where the text goes on once the note has ended")
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 40, tags: tags, startOffsets: offsets, isHeard: { $0 == "2" }), 0,
                       "another note's label does not count")
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 160, tags: tags, startOffsets: offsets, isHeard: { $0 == "3" }), 130,
                       "one unheard note of the two at that citation is enough")
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 160, tags: tags, startOffsets: offsets, isHeard: { $0 == "3" || $0 == "a" }), 160)
    }

    func testAFreshStartAtANoteBeforeAnyBodyChunkKeepsItsOffset() {
        XCTAssertEqual(Controls.restoredStartOffset(atOffset: 5, tags: [.aside("1"), nil], startOffsets: [5, 5]), 5)
    }

    // MARK: - Against the real planner

    func testARelaunchOnTheRealPlansNotesPlaysTheCitingSentenceThenTheNote() throws {
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true).chunks
        let tags = plan.map(\.footnote), offsets = plan.map(\.startOffset)
        let asides = tags.indices.filter { Controls.isAside(at: $0, tags: tags) }
        XCTAssertEqual(asides.count, 3)
        for index in asides {
            // The place the engine saves while this note reads is the aside's own offset (`SessionEngine` stores the
            // player's reported place). A relaunch plays from it.
            let saved = offsets[index]
            let start = Controls.restoredStartOffset(atOffset: saved, tags: tags, startOffsets: offsets)
            XCTAssertLessThan(start, saved, "\(index): the note would be dropped if the start stayed at the sentence's end")
            // The player starts the body chunk covering the offset and then follows the plan in order.
            let covering = try XCTUnwrap(plan.indices.first {
                tags[$0] == nil && start >= offsets[$0] && start < offsets[$0] + max(1, plan[$0].sourceLength)
            }, "\(index)")
            XCTAssertTrue(((covering + 1)..<index).allSatisfy { Controls.isAside(at: $0, tags: tags) },
                          "\(index): only notes sit between the chunk the start plays and this note")
            XCTAssertEqual(start, Controls.heldStartOffset(forChunkAt: index, tags: tags, startOffsets: offsets),
                           "a relaunch and a resume after a pause start in the same place")
        }
    }

    func testARelaunchAtEveryOtherChunkStartOfTheRealPlanKeepsItsOffset() {
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true).chunks
        let tags = plan.map(\.footnote), offsets = plan.map(\.startOffset)
        let noteOffsets = Set(tags.indices.filter { Controls.isAside(at: $0, tags: tags) }.map { offsets[$0] })
        for (index, offset) in offsets.enumerated() where !noteOffsets.contains(offset) {
            XCTAssertEqual(Controls.restoredStartOffset(atOffset: offset, tags: tags, startOffsets: offsets), offset, "\(index)")
        }
        let length = plan.last.map { $0.startOffset + $0.sourceLength } ?? 0
        for offset in 0...length where !noteOffsets.contains(offset) {
            XCTAssertEqual(Controls.restoredStartOffset(atOffset: offset, tags: tags, startOffsets: offsets), offset, "\(offset)")
        }
    }

    func testAPlanWithoutNotesNeverMovesAStart() {
        let plan = NarrationChunkPlanner.articlePlan("One sentence. Two sentence. Three.", asides: true).chunks
        let tags = plan.map(\.footnote), offsets = plan.map(\.startOffset)
        for offset in 0...40 {
            XCTAssertEqual(Controls.restoredStartOffset(atOffset: offset, tags: tags, startOffsets: offsets), offset)
        }
    }

    func testResumingDuringTheRealPlansNotesPlaysTheCitingSentenceThenTheNote() throws {
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true).chunks
        let tags = plan.map(\.footnote), offsets = plan.map(\.startOffset)
        let asides = tags.indices.filter { Controls.isAside(at: $0, tags: tags) }
        XCTAssertEqual(asides.count, 3)
        for index in asides {
            let held = try XCTUnwrap(Controls.heldStartOffset(forChunkAt: index, tags: tags, startOffsets: offsets), "\(index)")
            // The chunk a play from that offset starts: the body chunk covering it, as the client's lookup finds it.
            let covering = try XCTUnwrap(plan.indices.first {
                tags[$0] == nil && held >= offsets[$0] && held < offsets[$0] + max(1, plan[$0].sourceLength)
            }, "\(index)")
            XCTAssertLessThan(covering, index, "the sentence, not the text after the note")
            XCTAssertTrue(((covering + 1)..<index).allSatisfy { Controls.isAside(at: $0, tags: tags) },
                          "only notes sit between that chunk and this note, so the plan's own order reads the note next")
            XCTAssertLessThan(held, offsets[index], "an aside's own offset is the sentence's end and would skip the note")
        }
    }

    // MARK: - One note's chunks

    func testANoteRangeCoversEveryNeighbouringChunkWithItsLabelAndNoOther() {
        XCTAssertEqual(Controls.noteRange(containing: 1, tags: tags), 1..<2)
        XCTAssertEqual(Controls.noteRange(containing: 3, tags: tags), 3..<5)
        XCTAssertEqual(Controls.noteRange(containing: 4, tags: tags), 3..<5)
        XCTAssertEqual(Controls.noteRange(containing: 6, tags: tags), 6..<7, "the next aside has another label")
        XCTAssertEqual(Controls.noteRange(containing: 7, tags: tags), 7..<8)
        for index in [0, 2, 9, 10, -1, 11] {
            XCTAssertNil(Controls.noteRange(containing: index, tags: tags), "\(index)")
        }
    }

    // MARK: - The card's words

    func testTheCardHasTheSourcesLabelAndTheNotesTextWithoutTheLead() throws {
        let card = try XCTUnwrap(FootnoteCard.forChunk(
            at: 1, tags: [nil, .aside("3"), nil], texts: ["A sentence.", "Note 3. Smith, Tides, 2020.", "Next."]))
        XCTAssertEqual(card.label, "3")
        XCTAssertEqual(card.title, "Footnote 3")
        XCTAssertEqual(card.body, "Smith, Tides, 2020.")
        XCTAssertEqual(card.header(reading: false), "Footnote 3")
        XCTAssertEqual(card.header(reading: true), "Footnote 3 · Reading")
        XCTAssertEqual(card.voiceOverLabel, "Footnote 3. Smith, Tides, 2020.")
    }

    func testACardMadeFromItsTwoWordsReadsLikeOneTheChunksMade() throws {
        // The app's layout test draws cards it makes itself (#3777).
        let made = FootnoteCard(label: "3", body: "Smith, Tides, 2020.")
        let fromChunks = try XCTUnwrap(FootnoteCard.forChunk(
            at: 0, tags: [.aside("3")], texts: ["Note 3. Smith, Tides, 2020."]))
        XCTAssertEqual(made, fromChunks)
        XCTAssertEqual(made.voiceOverLabel, "Footnote 3. Smith, Tides, 2020.")
    }

    func testALetterLabelIsShownAsWritten() throws {
        let card = try XCTUnwrap(FootnoteCard.forChunk(at: 0, tags: [.aside("a")], texts: ["Note a. See the appendix."]))
        XCTAssertEqual(card.title, "Footnote a")
        XCTAssertEqual(card.body, "See the appendix.")
    }

    func testALongNotesCardHoldsTheWholeNoteFromEveryChunkTheCursorMayBeIn() throws {
        let tags: [Tag?] = [nil, .aside("2"), .aside("2"), nil]
        let texts = ["Body.", "Note 2. First half of a long note,", "second half of it.", "Body."]
        for index in [1, 2] {
            let card = try XCTUnwrap(FootnoteCard.forChunk(at: index, tags: tags, texts: texts), "\(index)")
            XCTAssertEqual(card.body, "First half of a long note, second half of it.", "\(index)")
        }
    }

    func testAnUnnumberedLabelUsesTheBareLead() throws {
        let card = try XCTUnwrap(FootnoteCard.forChunk(at: 0, tags: [.aside("some-long-label")], texts: ["Note. The text."]))
        XCTAssertEqual(card.title, "Footnote some-long-label")
        XCTAssertEqual(card.body, "The text.")
    }

    func testNoCardForAChunkThatIsNotANoteOrForANoteWithNothingToSay() {
        let tags: [Tag?] = [nil, .aside("1"), .definition("1")]
        let texts = ["Body.", "Note 1.", "Smith."]
        XCTAssertNil(FootnoteCard.forChunk(at: 0, tags: tags, texts: texts))
        XCTAssertNil(FootnoteCard.forChunk(at: 2, tags: tags, texts: texts))
        XCTAssertNil(FootnoteCard.forChunk(at: 1, tags: tags, texts: texts), "only the lead is left")
        XCTAssertNil(FootnoteCard.forChunk(at: 9, tags: tags, texts: texts))
        XCTAssertNil(FootnoteCard.forChunk(at: 1, tags: tags, texts: ["Body."]), "texts that do not line up with tags")
    }

    func testATextThatDoesNotStartWithTheLeadIsKeptWhole() throws {
        let card = try XCTUnwrap(FootnoteCard.forChunk(at: 0, tags: [.aside("4")], texts: ["Notebook entry for the fourth."]))
        XCTAssertEqual(card.body, "Notebook entry for the fourth.", "'Note 4.' with its full stop is the lead, not any word starting with Note")
    }

    // MARK: - Against the real planner

    private let article = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2][^b] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    [^b]: Kim, Ports, 2022.
    """

    private func plan() -> (tags: [Tag?], texts: [String]) {
        let chunks = NarrationChunkPlanner.articlePlan(article, asides: true).chunks
        return (chunks.map(\.footnote), chunks.map(\.text))
    }

    func testTheRealPlansNotesGetTheirCardsAndLeaveWithParagraphForward() throws {
        let (tags, texts) = plan()
        let asides = tags.indices.filter { Controls.isAside(at: $0, tags: tags) }
        XCTAssertEqual(asides.count, 3, "three notes, each short enough for one chunk")
        var bodies: [String] = []
        for index in asides {
            let card = try XCTUnwrap(FootnoteCard.forChunk(at: index, tags: tags, texts: texts), "\(index)")
            bodies.append(card.body)
            guard case .continueAt(let next) = Controls.paragraphForward(from: index, tags: tags) else {
                return XCTFail("a note in the middle of the text has a chunk after it: \(index)")
            }
            XCTAssertFalse(Controls.isAside(at: next, tags: tags), "¶› never lands on another note")
            let resume = try XCTUnwrap(Controls.resumeIndex(forChunkAt: index, tags: tags))
            XCTAssertLessThan(resume, index)
            XCTAssertNil(tags[resume], "the saved position is a body chunk, the end of the citing sentence")
        }
        XCTAssertEqual(bodies, ["Smith, Tides, 2020.", "Lee, Boats, 2021.", "Kim, Ports, 2022."])
    }

    func testTheRealPlansNotesCitedInOneSentenceShareOneExit() throws {
        let (tags, _) = plan()
        let asides = tags.indices.filter { Controls.isAside(at: $0, tags: tags) }
        let second = asides[1], third = asides[2]
        XCTAssertEqual(third, second + 1, "the notes of one sentence are read one after another")
        XCTAssertEqual(Controls.paragraphForward(from: second, tags: tags), Controls.paragraphForward(from: third, tags: tags))
        XCTAssertEqual(Controls.resumeIndex(forChunkAt: second, tags: tags), Controls.resumeIndex(forChunkAt: third, tags: tags))
    }

    // MARK: - Shapes only the real planner makes

    private func plan(of text: String) -> (tags: [Tag?], texts: [String]) {
        let chunks = NarrationChunkPlanner.articlePlan(text, asides: true).chunks
        return (chunks.map(\.footnote), chunks.map(\.text))
    }

    func testANoteInTheLastSentenceContinuesIntoTheNotesChapterWhereItsDefinitionIsRead() throws {
        let (tags, texts) = plan(of: "Body one. Last sentence.[^1]\n\n[^1]: Smith, Tides, 2020.")
        let aside = try XCTUnwrap(tags.firstIndex { $0 == .aside("1") })
        XCTAssertEqual(Controls.paragraphForward(from: aside, tags: tags), .continueAt(aside + 1))
        XCTAssertEqual(tags[aside + 1], .definition("1"), "the notes chapter follows; a note cut short is not heard, so it is read there")
        XCTAssertEqual(FootnoteCard.forChunk(at: aside, tags: tags, texts: texts)?.body, "Smith, Tides, 2020.")
        var heard = FootnoteHeardSet()
        XCTAssertEqual(heard.firstPlayableIndex(from: aside + 1, tags: tags, itemId: "a"), aside + 1)
        heard.recordPlayedToEnd(chunkAt: aside, tags: tags, itemId: "a")
        XCTAssertNil(heard.firstPlayableIndex(from: aside + 1, tags: tags, itemId: "a"), "a note heard to its end is passed over")
    }

    func testALongNoteTheRealPlannerSplitsGivesOneWholeCardFromEveryChunk() throws {
        let sentences = (1...12).map { "Sentence number \($0) of a very long note." }.joined(separator: " ")
        let (tags, texts) = plan(of: "A claim.[^1] Another one.\n\n[^1]: \(sentences)")
        let range = try XCTUnwrap(Controls.noteRange(containing: try XCTUnwrap(tags.firstIndex { $0 == .aside("1") }), tags: tags))
        XCTAssertGreaterThan(range.count, 1, "the planner splits this note")
        let bodies = Set(try range.map { try XCTUnwrap(FootnoteCard.forChunk(at: $0, tags: tags, texts: texts)).body })
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?.hasPrefix("Sentence number 1 of"), true)
        XCTAssertEqual(bodies.first?.hasSuffix("Sentence number 12 of a very long note."), true)
        XCTAssertEqual(Set(range.map { Controls.paragraphForward(from: $0, tags: tags) }).count, 1)
        XCTAssertEqual(Set(range.compactMap { Controls.resumeIndex(forChunkAt: $0, tags: tags) }).count, 1)
    }

    func testTheLeadIsStrippedForLabelsTheNormalizerRewrites() throws {
        let labels = ["1", "a", "note-3", "verylonglabelhere", ".", "!", "\u{1D44E}"]
        for label in labels {
            let (tags, texts) = plan(of: "A claim.[^\(label)] More.\n\n[^\(label)]: Smith 2020.")
            guard let aside = tags.firstIndex(where: { if case .aside = $0 { true } else { false } }) else { continue }
            let card = try XCTUnwrap(FootnoteCard.forChunk(at: aside, tags: tags, texts: texts), label)
            XCTAssertEqual(card.body, "Smith 2020.", "label \(label): \(texts[aside])")
        }
    }
}
