import Foundation
import XCTest
@testable import SessionKit

/// #3777 Design PR 6, the hidden half: what "Chime where cited" does at each cited note. The sequencer is a pure
/// state machine over the plan's footnote tags, so every rule is pinned here with no audio and no clock.
final class FootnoteChimeSequencerTests: XCTestCase {
    private typealias Tag = NarrationChunkPlanner.FootnoteTag
    private typealias Sequencer = FootnoteChimeSequencer

    private let item = "item-1"

    /// body 0, body 1, aside 1 (chunk 2), body 3, aside a + aside b (4, 5), body 6, then the notes chapter.
    private let tags: [Tag?] = [
        nil, nil, .aside("1"), nil, .aside("a"), .aside("b"), nil,
        .definition("1"), .definition("a"), .definition("b")
    ]

    private func step(
        _ sequencer: inout Sequencer,
        _ index: Int,
        tags: [Tag?]? = nil,
        mode: FootnoteMode = .chime,
        active: Bool = true,
        heard: FootnoteHeardSet = FootnoteHeardSet(),
        now: TimeInterval = 0
    ) -> Sequencer.Step {
        sequencer.willStartChunk(at: index, tags: tags ?? self.tags, itemId: item, mode: mode, appIsActive: active, heard: heard, now: now)
    }

    private func heard(_ labels: [String], tags: [Tag?]? = nil) -> FootnoteHeardSet {
        let plan = tags ?? self.tags
        var set = FootnoteHeardSet()
        for label in labels {
            if let index = plan.lastIndex(where: { $0 == .aside(label) }) {
                set.recordPlayedToEnd(chunkAt: index, tags: plan, itemId: item)
            }
        }
        return set
    }

    // MARK: - Modes that are not chime

    func testNothingChangesInAnyModeButChime() {
        for mode in [FootnoteMode.whereCited, .atEnd] {
            var sequencer = Sequencer()
            for index in tags.indices {
                XCTAssertEqual(step(&sequencer, index, mode: mode), .play, "\(mode) \(index)")
            }
            XCTAssertEqual(sequencer.card, .hidden)
        }
    }

    func testBodyAndDefinitionChunksAlwaysPlay() {
        var sequencer = Sequencer()
        for index in [0, 1, 3, 6, 7, 8, 9] {
            XCTAssertEqual(step(&sequencer, index), .play, "chunk \(index)")
        }
        XCTAssertEqual(sequencer.card, .hidden)
    }

    func testAnIndexOutsideThePlanPlays() {
        var sequencer = Sequencer()
        XCTAssertEqual(step(&sequencer, -1), .play)
        XCTAssertEqual(step(&sequencer, tags.count), .play)
        XCTAssertEqual(step(&sequencer, 0, tags: []), .play)
    }

    // MARK: - The tone

    func testTheStartOfACitationCuesOnceAndCarriesOnPastTheNote() {
        var sequencer = Sequencer()
        let run = Sequencer.Run(chunks: 2..<3, labels: ["1"])
        XCTAssertEqual(step(&sequencer, 2), .cue(run: run, continueAt: 3))
        XCTAssertEqual(sequencer.card, .offered(label: "1"))
    }

    func testSeveralNotesInOneSentenceGetOneToneAndTheCardOfTheFirst() {
        var sequencer = Sequencer()
        let run = Sequencer.Run(chunks: 4..<6, labels: ["a", "b"])
        XCTAssertEqual(step(&sequencer, 4), .cue(run: run, continueAt: 6))
        XCTAssertEqual(sequencer.card, .offered(label: "a"))
    }

    func testANoteSplitIntoSeveralChunksIsOneNote() {
        let split: [Tag?] = [nil, .aside("1"), .aside("1"), .aside("1"), nil]
        var sequencer = Sequencer()
        XCTAssertEqual(
            step(&sequencer, 1, tags: split),
            .cue(run: Sequencer.Run(chunks: 1..<4, labels: ["1"]), continueAt: 4)
        )
    }

    func testANoteInTheLastSentenceCarriesOnIntoTheNotesChapter() {
        let last: [Tag?] = [nil, .aside("1"), .definition("1")]
        var sequencer = Sequencer()
        guard case .cue(_, let continueAt) = step(&sequencer, 1, tags: last) else { return XCTFail("cues") }
        XCTAssertEqual(continueAt, 2, "an ignored note is read in the notes chapter")
    }

    func testCarryingOnPassesOverTheDefinitionsOfNotesAlreadyHeard() {
        let last: [Tag?] = [nil, .aside("a"), .aside("b"), .definition("a"), .definition("b")]
        var sequencer = Sequencer()
        guard case .cue(_, let continueAt) = step(&sequencer, 1, tags: last, heard: heard(["a"], tags: last)) else {
            return XCTFail("b was not heard, so it cues")
        }
        XCTAssertEqual(continueAt, 4)
    }

    func testTheEndOfTheTextHasNothingToContinueAt() {
        let end: [Tag?] = [nil, .aside("1")]
        var sequencer = Sequencer()
        XCTAssertEqual(
            step(&sequencer, 1, tags: end),
            .cue(run: Sequencer.Run(chunks: 1..<2, labels: ["1"]), continueAt: nil)
        )
    }

    // MARK: - Silent passes

    func testAnInactiveAppPassesTheNoteWithoutATone() {
        var sequencer = Sequencer()
        XCTAssertEqual(step(&sequencer, 2, active: false), .skip(continueAt: 3))
        XCTAssertEqual(step(&sequencer, 4, active: false), .skip(continueAt: 6))
        XCTAssertEqual(sequencer.card, .hidden)
    }

    func testANoteAlreadyHeardIsPassedWithoutATone() {
        var sequencer = Sequencer()
        XCTAssertEqual(step(&sequencer, 2, heard: heard(["1"])), .skip(continueAt: 3))
        XCTAssertEqual(sequencer.card, .hidden)
    }

    func testARunWithOneUnheardNoteStillCues() {
        var sequencer = Sequencer()
        guard case .cue = step(&sequencer, 4, heard: heard(["a"])) else { return XCTFail("b was not heard") }
        XCTAssertEqual(sequencer.card, .offered(label: "b"), "the card names the note not yet heard")
        XCTAssertEqual(sequencer.hearOfferedNote(tags: tags), 4)
        XCTAssertEqual(sequencer.card, .reading(label: "b"))
        var both = Sequencer()
        XCTAssertEqual(step(&both, 4, heard: heard(["a", "b"])), .skip(continueAt: 6))
    }

    func testANoteHeardInAnotherItemDoesNotCount() {
        var other = FootnoteHeardSet()
        other.recordPlayedToEnd(chunkAt: 2, tags: tags, itemId: "another-item")
        var sequencer = Sequencer()
        guard case .cue = step(&sequencer, 2, heard: other) else { return XCTFail("heard in another item") }
    }

    func testAPlayThatBeginsInsideARunPassesItSilently() {
        var sequencer = Sequencer()
        XCTAssertEqual(step(&sequencer, 5), .skip(continueAt: 6), "a resume or seek into the second note")
        XCTAssertEqual(sequencer.card, .hidden)
    }

    // MARK: - Hear note

    func testHearNoteMovesToTheRunAndReadsItThrough() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 4)
        XCTAssertEqual(sequencer.hearOfferedNote(tags: tags), 4)
        XCTAssertEqual(sequencer.card, .reading(label: "a"))
        XCTAssertEqual(step(&sequencer, 4), .play)
        XCTAssertEqual(step(&sequencer, 5), .play, "the second note of the sentence is read too")
        XCTAssertEqual(sequencer.card, .reading(label: "a"))
        XCTAssertEqual(step(&sequencer, 6), .play, "then the sentence after the citation")
        XCTAssertEqual(sequencer.card, .hidden, "the card has done its job once the note is read")
    }

    func testHearNoteNeedsAnOfferedCard() {
        var sequencer = Sequencer()
        XCTAssertNil(sequencer.hearOfferedNote(tags: tags))
        _ = step(&sequencer, 2)
        XCTAssertEqual(sequencer.hearOfferedNote(tags: tags), 2)
        XCTAssertNil(sequencer.hearOfferedNote(tags: tags), "already reading")
    }

    func testATimelineEntryReadsItsRunWithNoToneBeforeIt() {
        var sequencer = Sequencer()
        XCTAssertEqual(sequencer.beginHearing(chunkAt: 5, tags: tags), 4, "the run's first chunk, whichever of its notes was tapped")
        XCTAssertEqual(sequencer.card, .reading(label: "b"))
        XCTAssertEqual(step(&sequencer, 4), .play)
    }

    func testABodyChunkIsNotANoteToHear() {
        var sequencer = Sequencer()
        XCTAssertNil(sequencer.beginHearing(chunkAt: 3, tags: tags))
        XCTAssertNil(sequencer.beginHearing(chunkAt: 7, tags: tags), "a definition is not an aside")
        XCTAssertNil(sequencer.beginHearing(chunkAt: 99, tags: tags))
        XCTAssertEqual(sequencer.card, .hidden)
    }

    func testStopNoteGoesOnWithTheMainText() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 4)
        _ = sequencer.hearOfferedNote(tags: tags)
        XCTAssertEqual(sequencer.stopHearing(tags: tags, itemId: item, heard: FootnoteHeardSet()), Sequencer.Resume(continueAt: 6))
        XCTAssertEqual(sequencer.card, .hidden)
        XCTAssertNil(sequencer.stopHearing(tags: tags, itemId: item, heard: FootnoteHeardSet()), "nothing is being read")
    }

    func testAfterANoteIsHeardTheNextCitationCuesAgain() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        _ = sequencer.hearOfferedNote(tags: tags)
        _ = step(&sequencer, 2)
        _ = step(&sequencer, 3)
        guard case .cue = step(&sequencer, 4, heard: heard(["1"])) else { return XCTFail("a different note cues") }
        XCTAssertEqual(sequencer.card, .offered(label: "a"))
    }

    // MARK: - The card

    func testTheNextCitationReplacesTheCard() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2, now: 0)
        XCTAssertEqual(sequencer.card, .offered(label: "1"))
        _ = step(&sequencer, 4, now: 5)
        XCTAssertEqual(sequencer.card, .offered(label: "a"))
    }

    func testTheThirtySecondsRestartAtTheNextTone() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2, now: 0)
        _ = step(&sequencer, 4, now: 20)
        XCTAssertFalse(sequencer.expireCard(now: 30, voiceOverIsOnCard: false), "10 s after the second tone")
        XCTAssertTrue(sequencer.expireCard(now: 50, voiceOverIsOnCard: false))
    }

    func testASilentPassOverALaterCitationClearsTheEarlierCard() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        XCTAssertEqual(sequencer.card, .offered(label: "1"))
        XCTAssertEqual(step(&sequencer, 4, active: false), .skip(continueAt: 6))
        XCTAssertEqual(sequencer.card, .hidden)
        XCTAssertNil(sequencer.hearOfferedNote(tags: tags))
    }

    func testAReadingCardClearsWhenTheTextEndsRightAfterTheNote() {
        let last: [Tag?] = [nil, .aside("1"), .definition("1")]
        var sequencer = Sequencer()
        _ = step(&sequencer, 1, tags: last)
        XCTAssertEqual(sequencer.hearOfferedNote(tags: last), 1)
        XCTAssertEqual(step(&sequencer, 1, tags: last), .play)
        // The note is heard, so its definition is passed over and the text ends: the player asks about the end.
        XCTAssertEqual(step(&sequencer, last.count, tags: last), .play)
        XCTAssertEqual(sequencer.card, .hidden)
    }

    func testTheCardGoesAwayAfterThirtySecondsButNotBefore() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2, now: 100)
        XCTAssertFalse(sequencer.expireCard(now: 129.9, voiceOverIsOnCard: false))
        XCTAssertEqual(sequencer.card, .offered(label: "1"))
        XCTAssertTrue(sequencer.expireCard(now: 130, voiceOverIsOnCard: false))
        XCTAssertEqual(sequencer.card, .hidden)
        XCTAssertFalse(sequencer.expireCard(now: 500, voiceOverIsOnCard: false), "nothing left to expire")
    }

    func testTheCardStaysWhileVoiceOverIsOnItAndGoesOnceItLeaves() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2, now: 0)
        XCTAssertFalse(sequencer.expireCard(now: 90, voiceOverIsOnCard: true))
        XCTAssertEqual(sequencer.card, .offered(label: "1"))
        XCTAssertTrue(sequencer.expireCard(now: 91, voiceOverIsOnCard: false))
    }

    func testTheCardIsNotExpiredWhileANoteIsBeingRead() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2, now: 0)
        _ = sequencer.hearOfferedNote(tags: tags)
        XCTAssertFalse(sequencer.expireCard(now: 600, voiceOverIsOnCard: false))
        XCTAssertEqual(sequencer.card, .reading(label: "1"))
    }

    func testResetAndALeftModeClearTheCard() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        sequencer.reset()
        XCTAssertEqual(sequencer.card, .hidden)
        _ = step(&sequencer, 2)
        XCTAssertEqual(step(&sequencer, 0, mode: .atEnd), .play)
        XCTAssertEqual(sequencer.card, .hidden, "the picker changed while the card was up")
        XCTAssertNil(sequencer.hearOfferedNote(tags: tags))
    }

    // MARK: - Runs

    func testRunsAreTheContiguousAsidesAndNothingElse() {
        XCTAssertNil(Sequencer.run(containing: 3, tags: tags))
        XCTAssertNil(Sequencer.run(containing: 7, tags: tags))
        XCTAssertEqual(Sequencer.run(containing: 5, tags: tags), Sequencer.Run(chunks: 4..<6, labels: ["a", "b"]))
        XCTAssertEqual(Sequencer.run(containing: 2, tags: tags), Sequencer.Run(chunks: 2..<3, labels: ["1"]))
        XCTAssertNil(Sequencer.run(containing: -1, tags: tags))
    }

    // MARK: - Against the real planner

    func testWalkingARealPlanCuesEachCitationOnceAndTheNotesChapterReadsEveryNoteIgnored() {
        let article = """
        The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2][^3] Then they leave.

        [^1]: Smith, Tides, 2020.
        [^2]: Lee, Boats, 2021.
        [^3]: Park, Ports, 2022.
        """
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true)
        let plannedTags = plan.chunks.map(\.footnote)
        var sequencer = Sequencer()
        var cues: [Sequencer.Run] = []
        var played: [Int] = []
        var index: Int? = 0
        var steps = 0
        while let current = index, current < plannedTags.count, steps < 1_000 {
            steps += 1
            switch step(&sequencer, current, tags: plannedTags) {
            case .play:
                played.append(current)
                index = current + 1
            case .skip(let next):
                index = next
            case .cue(let run, let next):
                cues.append(run)
                index = next
            }
        }
        XCTAssertLessThan(steps, 1_000, "the walk ends")
        XCTAssertEqual(cues.map(\.labels), [["1"], ["2", "3"]], "one tone per citing sentence")
        for label in ["1", "2", "3"] {
            XCTAssertFalse(played.contains { plannedTags[$0] == .aside(label) }, "note \(label) is not read in the text")
            XCTAssertTrue(played.contains { plannedTags[$0] == .definition(label) }, "note \(label) is read in the notes chapter")
        }
        let body = plan.chunks.indices.filter { plannedTags[$0] == nil }
        XCTAssertEqual(body.filter { !played.contains($0) }, [], "no body chunk is dropped")
    }

    func testWalkingARealPlanWhileReadingEveryNoteHearsEachOnceAndTheChapterSkipsThem() {
        let article = "One claim.[^1] Another claim.[^2] The end.\n\n[^1]: First note.\n[^2]: Second note.\n"
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true)
        let plannedTags = plan.chunks.map(\.footnote)
        var sequencer = Sequencer()
        var set = FootnoteHeardSet()
        var played: [Int] = []
        var index: Int? = 0
        var steps = 0
        while let current = index, current < plannedTags.count, steps < 1_000 {
            steps += 1
            // The player passes over a heard note's definition in every inline mode; the sequencer does not repeat that.
            if set.skips(plannedTags[current], itemId: item) {
                index = current + 1
                continue
            }
            let result = step(&sequencer, current, tags: plannedTags, heard: set)
            switch result {
            case .play:
                played.append(current)
                set.recordPlayedToEnd(chunkAt: current, tags: plannedTags, itemId: item)
                index = current + 1
            case .skip(let next):
                index = next
            case .cue(_, let next):
                // The listener taps Hear note at once; the run is read, then playback goes on.
                if let start = sequencer.hearOfferedNote(tags: plannedTags) { index = start } else { index = next }
            }
        }
        XCTAssertLessThan(steps, 1_000, "the walk ends")
        for label in ["1", "2"] {
            XCTAssertEqual(played.filter { plannedTags[$0] == .aside(label) }.count, 1, "note \(label) read once")
            XCTAssertFalse(played.contains { plannedTags[$0] == .definition(label) }, "heard note \(label) is not read again")
        }
    }

    // MARK: - A rebuilt plan (audit of #5059)

    /// The plan with the citing sentence's chunk cut in two, as the player does at a seek or on a stand-in voice: every
    /// chunk from the cut on is one number later, so the note "1" is at 3, not 2.
    private var rebuilt: [Tag?] {
        var plan = tags
        plan.insert(nil, at: 1)
        return plan
    }

    func testANoteBeingReadIsStillReadWhenThePlanIsRebuiltBeforeIt() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        XCTAssertEqual(sequencer.hearOfferedNote(tags: tags), 2)
        XCTAssertEqual(step(&sequencer, 3, tags: rebuilt), .play, "the note's chunk is read, not cued again")
        XCTAssertEqual(sequencer.card, .reading(label: "1"))
        XCTAssertEqual(step(&sequencer, 4, tags: rebuilt), .play)
        XCTAssertEqual(sequencer.card, .hidden, "the text after the note clears the card, as it does in an unchanged plan")
    }

    /// The bundled voice cuts a long first chunk in two, so two chunks of the citing sentence sit before the note and the
    /// seam asks about the second one first. Every chunk on the way in is part of the request.
    func testEveryChunkThatLeadsIntoANoteBeingReadKeepsTheRequest() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        _ = sequencer.hearOfferedNote(tags: tags)
        for index in [1, 2, 3] {
            XCTAssertEqual(step(&sequencer, index, tags: rebuilt), .play, "chunk \(index) of the rebuilt plan")
            XCTAssertEqual(sequencer.card, .reading(label: "1"), "chunk \(index) of the rebuilt plan")
        }
        XCTAssertEqual(step(&sequencer, 4, tags: rebuilt), .play)
        XCTAssertEqual(sequencer.card, .hidden)
        // The next citation is a new request for nothing: it is cued as ever.
        XCTAssertEqual(step(&sequencer, 5, tags: rebuilt), .cue(run: Sequencer.Run(chunks: 5..<7, labels: ["a", "b"]), continueAt: 7))
    }

    func testHearNoteFindsTheOfferedNoteInARebuiltPlan() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        XCTAssertEqual(sequencer.hearOfferedNote(tags: rebuilt), 3)
        XCTAssertEqual(sequencer.card, .reading(label: "1"))
    }

    func testStopNoteGoesOnAfterTheNoteInARebuiltPlan() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        _ = sequencer.hearOfferedNote(tags: tags)
        let resume = sequencer.stopHearing(tags: rebuilt, itemId: item, heard: FootnoteHeardSet())
        XCTAssertEqual(resume, Sequencer.Resume(continueAt: 4))
        XCTAssertEqual(sequencer.card, .hidden)
    }

    func testANotePlanThatNoLongerCarriesTheNoteDropsItsCard() {
        var sequencer = Sequencer()
        _ = step(&sequencer, 2)
        XCTAssertNil(sequencer.hearOfferedNote(tags: [nil, nil, nil]))
        XCTAssertEqual(sequencer.card, .hidden)
    }
}
