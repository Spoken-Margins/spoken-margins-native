import Foundation
import XCTest
@testable import SessionKit

/// #4938: a landing on the listener's own written note gathers the notes just after it, so a burst takes one press, and the card
/// follows them as the source reaches each one.
final class SilentMarginLandingOwnTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func note(_ id: String, _ ms: Int, words: String? = nil) -> Interjection {
        Interjection(
            id: id, itemId: "item-1", sessionId: "session", targetType: .item, targetId: "item-1", createdAt: created,
            roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: ms),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "complete", transcript: words ?? "Note \(id)",
            cleanedTranscript: nil, displayText: nil, status: "active", captureKind: .written)
    }

    private func ownStop(_ id: String, _ ms: Int) -> SkimStop {
        SkimStop(kind: .margin, id: id, position: ms, isSilent: true, isOwnWritten: true)
    }

    private func chapter(_ id: String, _ ms: Int) -> SkimStop { SkimStop(kind: .chapter, id: id, position: ms) }

    /// Notes at 0, 20, 40 and 60 s.
    private let four = [("a", 0), ("b", 20_000), ("c", 40_000), ("d", 60_000)]

    private func list(_ notes: [(String, Int)], chapters: [SkimStop] = []) -> (SkimStops, [Interjection]) {
        (SkimStops(chapters: chapters, margins: notes.map { ownStop($0.0, $0.1) }), notes.map { note($0.0, $0.1) })
    }

    private func landing(on id: String, _ stops: SkimStops, _ margins: [Interjection]) throws -> SilentMarginLanding {
        let stop = try XCTUnwrap(stops.stops.first { $0.id == id })
        return try XCTUnwrap(SilentMarginLanding(own: stop, in: stops, margins: margins, itemId: "item-1"))
    }

    // MARK: Gathering

    func testALandingGathersTheNotesWithinThirtySecondsAndTheNextPressGoesPastThem() throws {
        let (stops, margins) = list(four)
        let first = try landing(on: "a", stops, margins)
        XCTAssertEqual(first.notes.map(\.marginId), ["a", "b"])
        XCTAssertEqual(first.subject, .yours)
        XCTAssertFalse(first.isApproximate)
        XCTAssertEqual(first.skimTarget(direction: .forward, playhead: 500, in: stops)?.stop.id, "c")
        XCTAssertEqual(first.skimTarget(direction: .forward, playhead: 21_000, in: stops)?.stop.id, "c")
        let third = try landing(on: "c", stops, margins)
        XCTAssertEqual(third.notes.map(\.marginId), ["c", "d"])
    }

    func testWithNoLandingAPressBetweenNotesGoesToTheNextNoteNotPastIt() {
        let (stops, _) = list(four)
        XCTAssertEqual(stops.next(playhead: 10_000)?.stop.id, "b")
    }

    func testGatheringReachesExactlyThirtySeconds() throws {
        let (atEdge, edgeMargins) = list([("a", 0), ("b", 30_000)])
        XCTAssertEqual(try landing(on: "a", atEdge, edgeMargins).notes.map(\.marginId), ["a", "b"])
        let (past, pastMargins) = list([("a", 0), ("b", 30_001)])
        XCTAssertEqual(try landing(on: "a", past, pastMargins).notes.map(\.marginId), ["a"])
    }

    func testGatheringNeverCrossesAnotherStop() throws {
        let (stops, margins) = list([("a", 0), ("b", 20_000)], chapters: [chapter("ch", 15_000)])
        let landing = try landing(on: "a", stops, margins)
        XCTAssertEqual(landing.notes.map(\.marginId), ["a"])
        XCTAssertEqual(landing.showsUntil, 14_999, "the card goes just before the next stop")
        XCTAssertEqual(landing.skimTarget(direction: .forward, playhead: 500, in: stops)?.stop.id, "ch")
    }

    func testAGoToInTheMiddleOfABurstStartsThereAndBackReachesTheEarlierNote() throws {
        let (stops, margins) = list(four)
        let landing = try landing(on: "b", stops, margins)
        XCTAssertEqual(landing.notes.map(\.marginId), ["b", "c"])
        XCTAssertEqual(landing.skimTarget(direction: .backward, playhead: 25_000, in: stops)?.stop.id, "a")
        XCTAssertEqual(landing.skimTarget(direction: .backward, playhead: 45_000, in: stops)?.stop.id, "a", "never c or b again")
        XCTAssertEqual(landing.skimTarget(direction: .forward, playhead: 25_000, in: stops)?.stop.id, "d")
    }

    // MARK: The card

    func testTheCardShowsEachNotesWordsAsTheSourceReachesIt() throws {
        let (stops, margins) = list([("a", 4_000), ("b", 5_000)])
        let landing = try landing(on: "a", stops, margins)
        XCTAssertEqual(landing.shownNote(playhead: 4_000).marginId, "a")
        XCTAssertEqual(landing.shownNote(playhead: 4_900).marginId, "a")
        XCTAssertEqual(landing.shownNote(playhead: 5_000).marginId, "b")
        XCTAssertEqual(landing.shownNote(playhead: 2_500).marginId, "a", "a seek that landed short shows the first")
        XCTAssertEqual(landing.card(noun: .episode, playhead: 5_200).detail, "Note b")
        XCTAssertEqual(landing.card(noun: .episode, playhead: 4_200).detail, "Note a")
    }

    func testTheCardGoesThirtySecondsAfterTheLastNoteOrBeforeASoonerStop() throws {
        let (alone, aloneMargins) = list([("a", 0), ("b", 10_000)])
        let byNote = try landing(on: "a", alone, aloneMargins)
        XCTAssertEqual(byNote.showsUntil, 40_000)
        XCTAssertTrue(byNote.isShowing(playhead: 40_000))
        XCTAssertFalse(byNote.isShowing(playhead: 40_001))
        XCTAssertTrue(byNote.isShowing(playhead: -2_000 + 1), "a seek that landed a little short")

        let (withStop, stopMargins) = list([("a", 0), ("b", 10_000)], chapters: [chapter("ch", 25_000)])
        XCTAssertEqual(try landing(on: "a", withStop, stopMargins).showsUntil, 24_999)
    }

    func testYourCardSaysYourMarginIsHereNeverAbout() throws {
        let (stops, margins) = list([("a", 0)])
        let card = try landing(on: "a", stops, margins).card(noun: .episode, playhead: 0)
        XCTAssertEqual(card.headline, "Your Margin is here")
        XCTAssertFalse(card.headline.contains("about"))
    }

    func testANoteWithNoWordsSaysTheSourcePlaysOn() throws {
        var blank = note("a", 0, words: "  ")
        blank.displayText = ""
        let stops = SkimStops(chapters: [], margins: [ownStop("a", 0)])
        let landing = try XCTUnwrap(SilentMarginLanding(own: stops.stops[0], in: stops, margins: [blank], itemId: "item-1"))
        XCTAssertNil(landing.words)
        XCTAssertEqual(landing.card(noun: .episode, playhead: 0).detail, "Not read aloud. The episode plays on.")
    }

    func testOwnWordsTakesTheFirstNonEmptyOfShownCleanedAndSaid() {
        var margin = note("a", 0, words: " said ")
        XCTAssertEqual(SilentMarginWords.ownWords(margin), "said")
        margin.cleanedTranscript = "cleaned"
        XCTAssertEqual(SilentMarginWords.ownWords(margin), "cleaned")
        margin.displayText = " \n"
        XCTAssertEqual(SilentMarginWords.ownWords(margin), "cleaned", "blank shown text is passed over")
        margin.displayText = "shown"
        XCTAssertEqual(SilentMarginWords.ownWords(margin), "shown")
        margin.displayText = nil; margin.cleanedTranscript = nil; margin.transcript = nil
        XCTAssertNil(SilentMarginWords.ownWords(margin))
    }

    // MARK: Guards and the old answers

    func testOnlyAnOwnWrittenStopWithItsMarginMakesALanding() {
        let stops = SkimStops(chapters: [], margins: [ownStop("a", 0)])
        XCTAssertNil(SilentMarginLanding(
            own: SkimStop(kind: .margin, id: "a", position: 0, isSilent: true), in: stops, margins: [note("a", 0)], itemId: "item-1"))
        XCTAssertNil(SilentMarginLanding(own: stops.stops[0], in: stops, margins: [], itemId: "item-1"))
    }

    func testALandingShortOfItsStopStillNeverReturnsTheStop() throws {
        // A list's go-to lands 500 ms short of where the stop list puts the note.
        let stops = SkimStops(chapters: [chapter("c0", 0)], margins: [ownStop("a", 10_000), ownStop("z", 50_000)])
        let landing = SilentMarginLanding(own: note("a", 10_000), position: 9_500, itemId: "item-1", unit: .milliseconds)
        XCTAssertEqual(landing.skimTarget(direction: .forward, playhead: 9_600, in: stops)?.stop.id, "z")
        XCTAssertEqual(landing.skimTarget(direction: .backward, playhead: 11_000, in: stops)?.stop.id, "c0")
    }

    func testAFriendsLandingGivesTodaysAnswers() throws {
        let silent = SkimStop(kind: .margin, id: "s", position: 300_000, isSilent: true)
        let stops = SkimStops(chapters: [chapter("c0", 0), chapter("c1", 600_000)], margins: [silent])
        let friend = SilentMarginLanding(
            itemId: "item-1", marginId: "s", subject: .friend("Sam"), words: "A thought.", isApproximate: true,
            position: 300_000, unit: .milliseconds)
        XCTAssertEqual(friend.notes, [.init(marginId: "s", position: 300_000, words: "A thought.")])
        XCTAssertEqual(friend.showsUntil, 330_000)
        XCTAssertEqual(friend.skimTarget(direction: .forward, playhead: 299_000, in: stops)?.stop.id, "c1")
        XCTAssertEqual(friend.skimTarget(direction: .backward, playhead: 300_500, in: stops)?.stop.id, "c0")
        XCTAssertEqual(friend.card(noun: .episode).headline, "Margin from Sam is about here")
        XCTAssertEqual(friend.card(noun: .episode, playhead: 310_000), friend.card(noun: .episode))
    }

    // MARK: A press from a note into a voiced Margin's lead-in

    func testStartPlayheadCountsFromTheLandingWhenTheSeekLandedShort() {
        let landing = SilentMarginLanding(own: note("a", 5_000), position: 5_000, itemId: "item-1", unit: .milliseconds)
        let voiced = SkimStop(kind: .margin, id: "v", position: 20_000)
        let target = SkimStops(chapters: [], margins: [ownStop("a", 5_000), voiced]).next(playhead: 5_000)!
        XCTAssertEqual(target.leadInStart, 5_000, "the note bounds the lead-in")
        XCTAssertEqual(SilentMarginLanding.startPlayhead(playhead: 4_500, landing: landing, target: target), 5_000)
        XCTAssertEqual(SkimStopRouting.startAction(playhead: 5_000, target: target), .playNow)
        XCTAssertEqual(SilentMarginLanding.startPlayhead(playhead: 4_500, landing: nil, target: target), 4_500)
        XCTAssertEqual(SilentMarginLanding.startPlayhead(playhead: 6_000, landing: landing, target: target), 6_000, "never earlier")
        XCTAssertEqual(SilentMarginLanding.startPlayhead(playhead: 60_000, landing: landing, target: target), 60_000, "card gone")
    }
}
