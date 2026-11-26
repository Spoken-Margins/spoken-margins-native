import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #3777: the on-device voice's footnote path, driven through real chunk ends the way a phone reaches them. The
/// SessionKit tests pin each rule (`NarrationChunkPlanner`, `FootnoteChimeSequencer`, `FootnoteNoteControls`) on its
/// own; these check that the client wires them together: the plan with notes is chosen at the play, the player steps
/// onto a note after its citing sentence, the chime passes over it with the tone, and Hear note and a Timeline tap
/// read it.
///
/// The article's plan with notes, as `NarrationChunkPlanner.spokenPlan(asides: true)` makes it (printed on Linux):
///
///     0  "The tide turns twice a day."
///     1  aside 1   "Note 1. Smith, Tides, 2020."
///     2  "It rests between turns. Boats wait for it."
///     3  aside 2   "Note 2. Lee, Boats, 2021."
///     4  "Then they leave."
///     5  definition 1, 6  definition 2 (the notes chapter)
///
/// `testThePlanTheseTestsWalkIsTheOneTheClientPlays` fails first if the planner changes that order.
@MainActor
final class SupertonicFootnoteClientTests: XCTestCase {
    private let article = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    """

    private func makeHarness(mode: FootnoteMode, cues: HarnessCounter, asides: Bool = true) throws -> SupertonicClientHarness {
        try SupertonicClientHarness(
            text: article, footnoteAsides: asides, footnoteMode: { mode }, footnoteCue: { cues.bump() })
    }

    func testThePlanTheseTestsWalkIsTheOneTheClientPlays() throws {
        let silenced = try XCTUnwrap(NarrationChunkPlanner.silencedSpeech(source: article, endingWith: article))
        let plan = NarrationChunkPlanner.spokenPlan(
            spokenText: silenced.text, articleText: article, articleSpokenStart: 0, asides: true)
        XCTAssertEqual(plan.chunks.map(\.footnote), [
            nil, .aside("1"), nil, .aside("2"), nil, .definition("1"), .definition("2"),
        ])
    }

    /// "Read where cited": the note is read right after the sentence that cites it, with its card, and no tone.
    func testReadWhereCitedStepsOntoEachNoteAfterItsCitingSentence() async throws {
        let cues = HarnessCounter()
        let harness = try makeHarness(mode: .whereCited, cues: cues)
        defer { harness.tearDown() }
        try await harness.start()
        XCTAssertTrue(harness.client.hasFootnoteAsides, "an article whose notes the app's rule reads where cited plays the plan with notes")
        XCTAssertNil(harness.client.currentFootnoteCard(), "the first sentence is not a note")

        let ontoNote1 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoNote1)
        let card1 = try XCTUnwrap(harness.client.currentFootnoteCard(), "note 1 is read right after its citing sentence")
        XCTAssertEqual(card1.label, "1")
        XCTAssertTrue(card1.body.contains("Smith, Tides"), card1.body)
        XCTAssertEqual(harness.client.chimeCardState(), .hidden, "the chime's card belongs to the chime mode only")

        let ontoText = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoText)
        XCTAssertNil(harness.client.currentFootnoteCard(), "the text goes on after the note")

        let ontoNote2 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoNote2)
        XCTAssertEqual(harness.client.currentFootnoteCard()?.label, "2")
        XCTAssertEqual(cues.value, 0, "no tone is played when the note is read anyway")
    }

    /// The same article, when the app's rule plans it with its notes at the end, plays the plain plan: no note chunk,
    /// so no card is ever asked for.
    func testAnArticleNotPlannedWithItsNotesPlaysThePlainPlan() async throws {
        let cues = HarnessCounter()
        let harness = try makeHarness(mode: .whereCited, cues: cues, asides: false)
        defer { harness.tearDown() }
        try await harness.start(waitingForRenders: 1)
        XCTAssertFalse(harness.client.hasFootnoteAsides)
        XCTAssertNil(harness.client.currentFootnoteCard())
        XCTAssertNil(harness.client.beginHearingFootnote(label: "1", targetId: harness.targetId),
                     "a Timeline tap finds no note in a plan without notes, so the app goes to the citation itself")
    }

    /// "Chime where cited": at the citing sentence's end the tone plays, the card offers the note, and the player passes
    /// over it to the text. Hear note goes back to the citing sentence and then reads the note.
    func testChimePassesOverTheNoteAndHearNoteReadsIt() async throws {
        let cues = HarnessCounter()
        let harness = try makeHarness(mode: .chime, cues: cues)
        defer { harness.tearDown() }
        try await harness.start()

        let pastNote1 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(pastNote1)
        XCTAssertEqual(cues.value, 1, "the tone marks the cited note")
        XCTAssertEqual(harness.client.chimeCardState(), .offered(label: "1"))
        XCTAssertEqual(harness.client.currentFootnoteCard()?.label, "1", "the offered card shows the note's words")
        XCTAssertNil(harness.client.footnoteContinuationSourceOffset(), "the player is on the text after the note, not on the note")

        let hearAt = try XCTUnwrap(harness.client.beginHearingOfferedFootnote(), "Hear note has a note to read")
        XCTAssertEqual(hearAt, 0, "Hear note goes back to the start of the sentence that cited the note")
        XCTAssertEqual(harness.client.chimeCardState(), .reading(label: "1"))
        let started = harness.playerStarts
        try harness.client.play(targetId: harness.targetId, seekingTo: hearAt)
        let replayedSentence = await harness.waitForPlayerStarts(started + 1)
        XCTAssertTrue(replayedSentence)
        XCTAssertEqual(harness.client.chimeCardState(), .reading(label: "1"), "Hear note's own seek keeps the note it asked for")

        let ontoNote1 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoNote1)
        XCTAssertNotNil(harness.client.footnoteContinuationSourceOffset(), "the player reads the note this time")
        XCTAssertEqual(harness.client.currentFootnoteCard()?.label, "1")
        XCTAssertEqual(cues.value, 1, "a note the listener asked for is read without another tone")

        let ontoText = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoText)
        XCTAssertEqual(harness.client.chimeCardState(), .hidden, "the card goes once the note was read to its end")

        let pastNote2 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(pastNote2)
        XCTAssertEqual(cues.value, 2, "the next cited note gets its own tone")
        XCTAssertEqual(harness.client.chimeCardState(), .offered(label: "2"))
    }

    /// A Timeline tap on "Footnote 1" before the item plays (`requestFootnoteHearing`): the app seeks to the citing
    /// sentence, and when the player reaches the note it reads it instead of offering it. A second tap, on "Footnote 2"
    /// while the item plays, is answered from the plan (`beginHearingFootnote`) and read the same way.
    func testATimelineTapReadsTheNoteInChimeMode() async throws {
        let cues = HarnessCounter()
        let harness = try makeHarness(mode: .chime, cues: cues)
        defer { harness.tearDown() }
        _ = try harness.client.prepareSpeechText(harness.text)
        XCTAssertNil(harness.client.beginHearingFootnote(label: "1", targetId: harness.targetId),
                     "nothing plays yet, so there is no plan to answer from")
        harness.client.requestFootnoteHearing(label: "1", targetId: harness.targetId)
        try harness.client.play(targetId: harness.targetId, seekingTo: 0)
        await harness.waitForRenders(2)
        let firstStarted = await harness.waitForPlayerStarts(1)
        XCTAssertTrue(firstStarted)

        let ontoNote1 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoNote1)
        XCTAssertEqual(harness.client.chimeCardState(), .reading(label: "1"), "the tapped note is read, not offered")
        XCTAssertEqual(harness.client.currentFootnoteCard()?.label, "1")
        XCTAssertEqual(cues.value, 0, "a note the listener asked for gets no tone")

        let ontoText = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoText)
        XCTAssertNil(harness.client.beginHearingFootnote(label: "2", targetId: "another item"),
                     "a tap on another item's note is not answered from this plan")
        let hearAt = try XCTUnwrap(harness.client.beginHearingFootnote(label: "2", targetId: harness.targetId),
                                   "the item plays its plan with notes, so the tap is answered from it")
        let started = harness.playerStarts
        // The citing sentence is the chunk now playing, so the seek moves its own player back (`resumeAction`, `.seekPlayer`).
        try harness.client.play(targetId: harness.targetId, seekingTo: hearAt)
        XCTAssertEqual(harness.playerStarts, started, "a seek inside the playing chunk keeps its player")

        let ontoNote2 = await harness.finishPlayingChunkAndWaitForTheNext()
        XCTAssertTrue(ontoNote2)
        XCTAssertEqual(harness.client.chimeCardState(), .reading(label: "2"))
        XCTAssertEqual(harness.client.currentFootnoteCard()?.label, "2")
        XCTAssertEqual(cues.value, 0)
    }
}
