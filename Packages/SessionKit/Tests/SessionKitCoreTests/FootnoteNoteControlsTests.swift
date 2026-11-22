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
