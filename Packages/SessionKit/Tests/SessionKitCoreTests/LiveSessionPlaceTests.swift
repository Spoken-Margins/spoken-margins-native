import Foundation
import XCTest
@testable import SessionKit

/// #2707: a Margin is placed by page, percent or chapter, in the unit the listener used, and never as a time.
final class LiveSessionPlaceTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func place(_ unit: LiveSessionPlace.Unit, _ value: Double) -> LiveSessionPlace { LiveSessionPlace(unit: unit, value: value)! }

    // MARK: Reading what the listener types

    func testTypedTableForAPaperBook() {
        let page = LiveSessionPlace.Unit.page
        let table: [(String, LiveSessionPlace?)] = [
            ("p. 118", place(.page, 118)),
            ("p.118", place(.page, 118)),
            ("p118", place(.page, 118)),
            ("pg 12", place(.page, 12)),
            ("page 118", place(.page, 118)),
            ("Page 118.", place(.page, 118)),
            ("PAGE 118", place(.page, 118)),
            ("  page   118  ", place(.page, 118)),
            ("page number 118", place(.page, 118)),
            ("page no. 118", place(.page, 118)),
            ("page #118", place(.page, 118)),
            ("118", place(.page, 118)),
            ("0", place(.page, 0)),
            ("I'm on page 118", place(.page, 118)),
            ("page one hundred and eighteen", place(.page, 118)),
            ("page twenty-one", place(.page, 21)),
            ("ch 7", place(.chapter, 7)),
            ("ch. 7", place(.chapter, 7)),
            ("ch7", place(.chapter, 7)),
            ("chapter 7", place(.chapter, 7)),
            ("chapter seven", place(.chapter, 7)),
            ("Chapter Seven", place(.chapter, 7)),
            ("chapter VII", place(.chapter, 7)),
            ("chapter iv", place(.chapter, 4)),
            ("40%", place(.percent, 40)),
            ("40 %", place(.percent, 40)),
            ("40 percent", place(.percent, 40)),
            ("40 per cent", place(.percent, 40)),
            ("about 40 percent", place(.percent, 40)),
            ("forty percent", place(.percent, 40)),
            ("40.5%", place(.percent, 40.5)),
            ("100%", place(.percent, 100)),
            ("12:30", place(.time, 750_000)),
            ("1:12:30", place(.time, 4_350_000)),
            // Other languages: the keyword is read, a number word is not (no guessing).
            ("página 118", place(.page, 118)),
            ("Seite 12", place(.page, 12)),
            ("chapitre 7", place(.chapter, 7)),
            ("capítulo 7", place(.chapter, 7)),
            ("\u{FF11}\u{FF11}\u{FF18}", place(.page, 118)), // full-width digits
            ("page \u{0661}\u{0661}\u{0668}", place(.page, 118)), // Arabic-Indic digits
            ("capítulo siete", nil),
            ("chapitre sept", nil),
            ("sieben", nil),
            // Not places.
            ("", nil),
            ("   ", nil),
            ("page", nil),
            ("p", nil),
            ("this page is blank", nil),
            ("page -5", nil),
            ("page 11.8", nil),
            ("page 1000000", nil),
            ("150%", nil),
            ("the introduction", nil),
            ("chapter I think", nil),
        ]
        for (text, expected) in table {
            XCTAssertEqual(LiveSessionPlace.parse(text, defaultUnit: page), expected, "“\(text)”")
        }
    }

    func testWordsWithMoreThanAPlaceInThemAreKeptAsTyped() {
        for text in ["Chapter 7: The Wall", "Chapter 3, page 40", "Chapter 10 (40%)", "page 118 of 300", "near the end of chapter 3"] {
            XCTAssertNotNil(LiveSessionPlace.parse(text, defaultUnit: .page), text)
            XCTAssertNil(LiveSessionPlace.parseWhole(text, defaultUnit: .page), text)
            let read = LiveSessionWhere.interpret(clockText: "", whereText: text, kind: .paper)
            XCTAssertNil(read.place, text)
            XCTAssertEqual(read.text, text, "nothing the listener typed is thrown away")
        }
        XCTAssertEqual(LiveSessionPlace.parseWhole("p. 118.", defaultUnit: .page), place(.page, 118))
        XCTAssertEqual(LiveSessionPlace.parseWhole("chapter seven", defaultUnit: .page), place(.chapter, 7))
        XCTAssertEqual(LiveSessionPlace.parseWhole("40%", defaultUnit: .page), place(.percent, 40))
    }

    func testOrdinarySentencesAndRangesAreNotPlaces() {
        for text in ["finished the chapter. Two things stood out", "see page. Two", "pp. 12-14", "page 1e3", "page 12-14"] {
            XCTAssertNil(LiveSessionPlace.parseWhole(text, defaultUnit: .page), text)
        }
        XCTAssertNil(LiveSessionPlace.hear(in: "finished the chapter. Two things stood out"))
        XCTAssertNil(LiveSessionPlace.hear(in: "pp. 12-14"))
    }

    func testABareNumberTakesTheFieldsUnit() {
        XCTAssertEqual(LiveSessionPlace.parse("7", defaultUnit: .chapter), place(.chapter, 7))
        XCTAssertEqual(LiveSessionPlace.parse("40", defaultUnit: .percent), place(.percent, 40))
        XCTAssertEqual(LiveSessionPlace.parse("seven", defaultUnit: .chapter), place(.chapter, 7))
        XCTAssertNil(LiveSessionPlace.parse("140", defaultUnit: .percent))
        // In a clock field a bare number is minutes, as it always was.
        XCTAssertEqual(LiveSessionPlace.parse("2", defaultUnit: .time), place(.time, 120_000))
        XCTAssertEqual(LiveSessionPlace.defaultUnit(for: .paper), .page)
        XCTAssertEqual(LiveSessionPlace.defaultUnit(for: .audiobook), .chapter)
        XCTAssertEqual(LiveSessionPlace.defaultUnit(for: .other), .percent)
        XCTAssertEqual(LiveSessionPlace.offeredUnits(for: .audiobook), [.chapter, .page, .percent])
        XCTAssertEqual(LiveSessionPlace.offeredUnits(for: .paper), [.page, .chapter, .percent])
    }

    func testAClockIsLeftAsWordsInAChapterOrPageField() {
        XCTAssertNil(LiveSessionPlace.parse("12:30", defaultUnit: .page, allowsTime: false))
        XCTAssertEqual(LiveSessionPlace.parse("page 12", defaultUnit: .page, allowsTime: false), place(.page, 12))
    }

    func testVeryLongTextIsNotATypedPlaceButASaidOneIsStillHeard() {
        let padding = String(repeating: "and so on ", count: 60)
        XCTAssertNil(LiveSessionPlace.parse("page 118 " + padding, defaultUnit: .page))
        XCTAssertNil(LiveSessionPlace.parse(String(repeating: "a", count: 5_000), defaultUnit: .page))
        XCTAssertEqual(LiveSessionPlace.hear(in: "I think this is page 118. " + padding), place(.page, 118))
        XCTAssertNil(LiveSessionPlace.hear(in: padding + String(repeating: "x ", count: 2_000) + "page 118"))
    }

    func testOnlyANumberNextToItsUnitIsHeard() {
        XCTAssertEqual(LiveSessionPlace.hear(in: "I think this is chapter 5"), place(.chapter, 5))
        XCTAssertEqual(LiveSessionPlace.hear(in: "About 40 percent of the way, I'm on page 118"), place(.percent, 40))
        XCTAssertEqual(LiveSessionPlace.hear(in: "I'm on page 118, this contradicts chapter 2"), place(.page, 118))
        XCTAssertNil(LiveSessionPlace.hear(in: "I'm at 118"))
        XCTAssertNil(LiveSessionPlace.hear(in: "Let's pick this up on the call at 3:30"))
        XCTAssertNil(LiveSessionPlace.hear(in: "Johnny was just talking about the budget"))
        XCTAssertNil(LiveSessionPlace.hear(in: ""))
    }

    func testPlacesNormaliseTheirWords() {
        XCTAssertEqual(place(.page, 118).label, "page 118")
        XCTAssertEqual(place(.page, 118).sentenceLabel, "Page 118")
        XCTAssertEqual(place(.percent, 40.5).label, "40.5%")
        XCTAssertEqual(place(.percent, 40).label, "40%")
        XCTAssertEqual(place(.chapter, 7).label, "chapter 7")
        XCTAssertEqual(place(.time, 4_350_000).label, "1:12:30")
        XCTAssertNil(LiveSessionPlace(unit: .page, value: 11.5))
        XCTAssertNil(LiveSessionPlace(unit: .percent, value: 101))
        XCTAssertNil(LiveSessionPlace(unit: .page, value: -1))
        XCTAssertNil(LiveSessionPlace(unit: .page, value: .nan))
    }

    func testTheClockFieldAndTheChapterFieldAreReadTogether() {
        let paper = LiveSessionWhere.interpret(clockText: "ignored", whereText: "p. 100", kind: .paper)
        XCTAssertNil(paper.positionMs)
        XCTAssertEqual(paper.place, place(.page, 100))
        XCTAssertEqual(paper.text, "Page 100")

        let audiobook = LiveSessionWhere.interpret(clockText: "1:23:10", whereText: "chapter seven", kind: .audiobook)
        XCTAssertEqual(audiobook.positionMs, 4_990_000)
        XCTAssertEqual(audiobook.place, place(.chapter, 7))

        // "40%" typed in the clock field is a percent, not a time.
        let ebook = LiveSessionWhere.interpret(clockText: "40%", whereText: "", kind: .other)
        XCTAssertNil(ebook.positionMs)
        XCTAssertEqual(ebook.place, place(.percent, 40))
        XCTAssertEqual(ebook.text, "40%")

        // Ending: a bare number is in the unit the session started in.
        let stopped = LiveSessionWhere.interpret(clockText: "", whereText: "140", kind: .audiobook, defaultUnit: .page)
        XCTAssertEqual(stopped.place, place(.page, 140))
        XCTAssertEqual(stopped.text, "Page 140")

        // Words it can't read stay as the listener typed them.
        let intro = LiveSessionWhere.interpret(clockText: "", whereText: "the introduction", kind: .paper)
        XCTAssertNil(intro.place)
        XCTAssertEqual(intro.text, "the introduction")
        let blank = LiveSessionWhere.interpret(clockText: "  ", whereText: " ", kind: .meeting)
        XCTAssertNil(blank.positionMs)
        XCTAssertNil(blank.text)
    }

    // MARK: Estimating between checkpoints

    private func paperSession() -> LiveSession {
        var live = LiveSession(id: "p", kind: .paper, title: "The book", startedAt: start, endedAt: at(40))
        live.startPlace = place(.page, 100)
        live.endPlace = place(.page, 140)
        return live
    }

    func testAMarginHalfwayBetweenPage100And140IsAboutPage120() {
        var live = paperSession()
        live.margins = [live.margin(id: "a", text: "Hmm", markedAt: at(20)), live.margin(id: "b", text: "Hm", markedAt: at(10))]
        XCTAssertEqual(live.positionUnit, .page)
        XCTAssertTrue(live.usesPlaces)
        let half = LiveSessionPlaceMap.located(live.margins[0], in: live)
        XCTAssertEqual(half, LiveSessionPlaceMap.Located(place: place(.page, 120), basis: .estimate))
        XCTAssertEqual(half?.label, "about page 120")
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[1], in: live), "about page 110")
    }

    func testAMarginAfterTheEndIsAtTheEndPlace() {
        var live = paperSession()
        live.margins = [live.margin(id: "late", text: "Oops", markedAt: at(45))]
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[0], in: live), "about page 140")
    }

    func testWhatTheListenerSaidIsNotAnEstimate() {
        var live = paperSession()
        var said = live.margin(id: "a", text: "I'm on page 118", markedAt: at(20))
        said.place = place(.page, 118)
        live.margins = [said]
        let located = LiveSessionPlaceMap.located(said, in: live)
        XCTAssertEqual(located?.basis, .said)
        XCTAssertEqual(located?.label, "page 118")
        XCTAssertEqual(located?.sentenceLabel, "Page 118")
    }

    func testAKeptMarginPlaceIsACheckpointForTheOthers() {
        var live = paperSession()
        var kept = live.margin(id: "k", text: "", markedAt: at(10))
        kept.place = place(.page, 130)
        live.margins = [kept, live.margin(id: "b", text: "", markedAt: at(25))]
        // Between page 130 at 10 minutes and page 140 at 40 minutes, halfway.
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[1], in: live), "about page 135")
    }

    func testWithoutAnEndThereIsNoEstimateBeyondTheLastCheckpoint() {
        var live = paperSession()
        live.endedAt = nil
        live.endPlace = nil
        live.margins = [live.margin(id: "a", text: "", markedAt: at(20))]
        XCTAssertNil(LiveSessionPlaceMap.located(live.margins[0], in: live))
    }

    func testBetweenUnitsThereIsNoGuessing() throws {
        var live = paperSession()
        live.endPlace = place(.percent, 50)
        live.margins = [live.margin(id: "a", text: "", markedAt: at(20))]
        XCTAssertNil(LiveSessionPlaceMap.located(live.margins[0], in: live))
        try LiveSessionPlaceMap.validate(start: live.startPlace, end: live.endPlace)
        // And a Margin that names a chapter in a page-placed session keeps it as said, without moving the page.
        var chapter = live.margin(id: "c", text: "ch 7", markedAt: at(30))
        chapter.place = place(.chapter, 7)
        live.margins = [chapter]
        XCTAssertNil(LiveSessionPlaceMap.located(chapter, in: live))
        XCTAssertEqual(chapter.place?.label, "chapter 7")
    }

    func testAChapterIsTheOneItHasReached() {
        var live = LiveSession(id: "a", kind: .audiobook, startedAt: start, endedAt: at(60))
        live.startPlace = place(.chapter, 3)
        live.endPlace = place(.chapter, 6)
        live.margins = [live.margin(id: "a", text: "", markedAt: at(35))] // 3 + 32/60 × 3 = 4.6
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[0], in: live), "about chapter 4")
    }

    func testAPercentRoundsToTheNearestPercent() {
        var live = LiveSession(id: "e", kind: .other, startedAt: start, endedAt: at(30))
        live.startPlace = place(.percent, 10)
        live.endPlace = place(.percent, 20)
        live.margins = [live.margin(id: "a", text: "", markedAt: at(10))] // 13.33
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[0], in: live), "about 13%")
    }

    func testASessionWithAClockIsPlacedByTheClockAsBefore() {
        var live = LiveSession(id: "m", kind: .audiobook, startedAt: start, endedAt: at(60), startPositionMs: 0, endPositionMs: 3_600_000)
        var margin = live.margin(id: "a", text: "page 118", markedAt: at(30))
        margin.place = place(.page, 118)
        live.margins = [margin]
        XCTAssertEqual(live.positionUnit, .time)
        XCTAssertFalse(live.usesPlaces)
        XCTAssertNil(LiveSessionPlaceMap.located(margin, in: live))
        XCTAssertEqual(LiveSessionPositionMap.position(of: margin, in: live)?.ms, 1_800_000)
    }

    func testAPaperBookIgnoresAClockItHadBeforeItsKindChanged() {
        var live = LiveSession(id: "m", kind: .paper, startedAt: start, startPositionMs: 0)
        live.startPlace = place(.page, 5)
        XCTAssertEqual(live.positionUnit, .page)
    }

    // MARK: Ending, checkpoints that disagree

    func testAnEndBeforeTheStartInTheSameUnitIsRefusedInPlainWords() {
        var live = LiveSession(id: "p", kind: .paper, startedAt: start)
        live.startPlace = place(.page, 140)
        XCTAssertThrowsError(try LiveSessionEnd.end(&live, when: .now, tappedAt: at(30), endPositionMs: nil, endWhere: "Page 100", endPlace: place(.page, 100))) {
            XCTAssertEqual($0 as? LiveSessionPlaceMap.Failure, .endBeforeStart(.page))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "The page you stopped at is before the page you started at. Check where you were when you started and stopped.")
        }
        XCTAssertNil(live.endedAt, "nothing changes when it is refused")
        XCTAssertNil(live.endPlace)
    }

    func testEndingKeepsTheEndPlaceAndANewUnitIsNotComparedWithTheOld() throws {
        var live = LiveSession(id: "p", kind: .paper, startedAt: start)
        live.startPlace = place(.page, 100)
        try LiveSessionEnd.end(&live, when: .minutesAgo(15), tappedAt: at(45), endPositionMs: nil, endWhere: "Chapter 9", endPlace: place(.chapter, 9))
        XCTAssertEqual(live.endPlace, place(.chapter, 9))
        XCTAssertEqual(live.endedAt, at(30))
    }

    func testCheckpointsThatDisagreeAreSaidAndLeaveNoEstimateBetweenThem() {
        var live = paperSession()
        var wrong = live.margin(id: "w", text: "I'm on page 150", markedAt: at(10))
        wrong.place = place(.page, 150)
        live.margins = [wrong, live.margin(id: "b", text: "", markedAt: at(25))]
        let conflicts = LiveSessionPlaceMap.conflicts(in: live)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(
            conflicts.first?.description(timeZone: utc),
            "You gave page 150 at 10:10 and page 140 at 10:40. That goes backwards, so check one of them."
        )
        XCTAssertNil(LiveSessionPlaceMap.located(live.margins[1], in: live), "neither is chosen silently")
        XCTAssertEqual(LiveSessionPlaceMap.conflicts(in: paperSession()), [])
    }

    // MARK: A meeting's clock

    func testALateJoinerIsToldTheEndClockDisagreesWithTheStart() {
        // Typed 0:00 at the start, joined ten minutes late: the clock reads 55:00 after 45 minutes.
        var live = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(45), startPositionMs: 0, endPositionMs: 3_300_000)
        let check = LiveSessionPlaceMap.clockCheck(for: live)
        XCTAssertEqual(check?.impliedStartMs, 600_000)
        XCTAssertEqual(
            check?.note,
            "You gave 0:00 at the start, but the clock showed 55:00 after 45:00, which puts the start at 10:00. Margins are placed between the two you gave."
        )
        XCTAssertTrue(LiveSessionEdit.useImpliedStart(on: &live))
        XCTAssertEqual(live.startPositionMs, 600_000)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: live), 1, accuracy: 1e-9)
        XCTAssertNil(LiveSessionPlaceMap.clockCheck(for: live))
        XCTAssertFalse(LiveSessionEdit.useImpliedStart(on: &live))
    }

    func testAMeetingThatAgreesOrHasNoEndClockHasNoCheck() {
        let agrees = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(45), startPositionMs: 0, endPositionMs: 2_730_000)
        XCTAssertNil(LiveSessionPlaceMap.clockCheck(for: agrees), "30 seconds out is within a minute")
        let noEnd = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(45), startPositionMs: 0)
        XCTAssertNil(LiveSessionPlaceMap.clockCheck(for: noEnd))
        let book = LiveSession(id: "a", kind: .audiobook, startedAt: start, endedAt: at(45), startPositionMs: 0, endPositionMs: 600_000)
        XCTAssertNil(LiveSessionPlaceMap.clockCheck(for: book), "a book is paused and sped up, so its clock is not real time")
    }

    func testAStartBeforeTheMeetingClockBeganIsSaid() {
        let lobby = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(30), startPositionMs: 0, endPositionMs: 1_500_000)
        XCTAssertTrue(LiveSessionPlaceMap.clockCheck(for: lobby)?.note.contains("which puts the start at before its own clock began") ?? false)
    }

    // MARK: Heard in a Margin

    func testAPlaceSaidInAMarginIsOfferedAndKeptWithOneTap() {
        var live = paperSession()
        live.margins = [live.margin(id: "a", text: "I'm on page 118, this contradicts chapter 2", markedAt: at(20)), live.margin(id: "b", text: "nothing here", markedAt: at(21))]
        XCTAssertEqual(live.margins[0].heardPlace, place(.page, 118))
        XCTAssertNil(live.margins[1].heardPlace)
        XCTAssertTrue(live.keepHeardPlace(forMarginId: "a"))
        XCTAssertEqual(live.margins[0].place, place(.page, 118))
        XCTAssertNil(live.margins[0].heardPlace, "kept, so no longer offered")
        XCTAssertFalse(live.keepHeardPlace(forMarginId: "b"))
        // It is now a checkpoint for the Margins around it.
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[1], in: live), "about page 119")
    }

    func testTurningDownAHeardPlaceKeepsItOut() {
        var live = paperSession()
        live.margins = [live.margin(id: "a", text: "see page 12 of the other book", markedAt: at(20))]
        XCTAssertTrue(live.declineHeardPlace(forMarginId: "a"))
        XCTAssertNil(live.margins[0].heardPlace)
        XCTAssertNil(live.margins[0].place)
    }

    // MARK: Compatibility

    func testASessionFromAnEarlierBuildReadsUnchanged() throws {
        let old = """
        {"id":"s","kind":"audiobook","title":"Book","startedAt":"2026-03-04T10:00:00.000Z","endedAt":"2026-03-04T11:00:00.000Z",
         "startPositionMs":0,"endPositionMs":3600000,"startWhere":"Chapter 4","endWhere":"Chapter 6",
         "margins":[{"id":"a","text":"Hmm","markedAt":"2026-03-04T10:30:00.000Z","sessionOffsetMs":1800000,"whereNote":"page 118","isBlindMark":false}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractions
        let live = try decoder.decode(LiveSession.self, from: Data(old.utf8))
        XCTAssertNil(live.startPlace)
        XCTAssertNil(live.endPlace)
        XCTAssertNil(live.margins[0].place)
        XCTAssertEqual(live.positionUnit, .time)
        XCTAssertEqual(LiveSessionPositionMap.position(of: live.margins[0], in: live)?.ms, 1_800_000)
        XCTAssertEqual(live.bracket, "Chapter 4 to Chapter 6")
    }

    func testASessionWithNoPlacesWritesNoNewKeys() throws {
        var live = LiveSession(id: "s", kind: .audiobook, startedAt: start, endedAt: at(60), startPositionMs: 0, endPositionMs: 3_600_000)
        live.margins = [live.margin(id: "a", text: "Hmm", markedAt: at(30), whereNote: "page 118")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601withFractions
        let json = String(decoding: try encoder.encode(live), as: UTF8.self)
        for key in ["startPlace", "endPlace", "\"place\"", "declinedHeardPlace"] {
            XCTAssertFalse(json.contains(key), "\(key) in \(json)")
        }
    }

    func testPlacesRoundTripThroughTheStore() throws {
        var live = paperSession()
        var margin = live.margin(id: "a", text: "page 118", markedAt: at(20))
        margin.place = place(.page, 118)
        live.margins = [margin]
        let directory = FileManager.default.temporaryDirectory.appending(path: "places-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LiveSessionStore.save(live, in: directory)
        XCTAssertEqual(LiveSessionStore.load(from: directory), live)
    }

    func testOpeningTheDetailsOfAnEarlierSessionRewritesNothing() {
        var live = LiveSession(id: "a", kind: .audiobook, startedAt: start, startPositionMs: 0, startWhere: "3")
        let before = live
        LiveSessionEdit.setStartWhere("3", on: &live)
        XCTAssertEqual(live, before)
        LiveSessionEdit.setStartWhere(" 3 ", on: &live)
        XCTAssertEqual(live, before)
    }

    func testTheClockStartIsNotOfferedWhenItWouldBeNegative() {
        var lobby = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(15), startPositionMs: 0, endPositionMs: 600_000)
        XCTAssertEqual(LiveSessionPlaceMap.clockCheck(for: lobby)?.impliedStartMs, -300_000)
        XCTAssertFalse(LiveSessionEdit.useImpliedStart(on: &lobby))
        XCTAssertEqual(lobby.startPositionMs, 0)
    }

    func testALateEndHasNoClockCheckBecauseTheClockMayHaveBeenReadAtEitherTime() {
        var live = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(45), startPositionMs: 0, endPositionMs: 3_300_000)
        live.endTappedAt = at(60)
        XCTAssertNil(LiveSessionPlaceMap.clockCheck(for: live))
    }

    func testEditingTheStartPlaceReadsAndNormalisesIt() {
        var live = LiveSession(id: "p", kind: .paper, startedAt: start)
        LiveSessionEdit.setStartWhere(" p. 100 ", on: &live)
        XCTAssertEqual(live.startPlace, place(.page, 100))
        XCTAssertEqual(live.startWhere, "Page 100")
        LiveSessionEdit.setStartWhere("the introduction", on: &live)
        XCTAssertNil(live.startPlace)
        XCTAssertEqual(live.startWhere, "the introduction")
        LiveSessionEdit.setStartWhere("  ", on: &live)
        XCTAssertNil(live.startPlace)
        XCTAssertNil(live.startWhere)
    }

    // MARK: What the listener reads

    private func paperRecord() -> LiveSessionRecord {
        var live = paperSession()
        live.startWhere = "Page 100"
        live.endWhere = "Page 140"
        var said = live.margin(id: "a", text: "This contradicts chapter 2", markedAt: at(20))
        said.place = place(.page, 118)
        said.whereNote = "page 118"
        live.margins = [said, live.margin(id: "b", text: "Nice", markedAt: at(30))]
        let notes = LiveSessionText.notes(live)
        return LiveSessionRecord(itemId: "i", session: live, transcript: nil, placed: notes.placed)
    }

    func testTheMarkdownNamesThePageAndNeverATime() {
        let markdown = LiveSessionMarkdown.render(paperRecord(), timeZone: utc)
        XCTAssertTrue(markdown.contains("- Where: Page 100 to Page 140"), markdown)
        XCTAssertTrue(markdown.contains("## 1. Page 118\n\nThis contradicts chapter 2\n\nPosition: You said page 118 · 20:00 into the session"), markdown)
        XCTAssertTrue(markdown.contains("## 2. About page 129\n\nNice\n\nPosition: Estimate about page 129 · 30:00 into the session"), markdown)
        XCTAssertFalse(markdown.contains("About 20:00"), markdown)
        XCTAssertFalse(markdown.contains("About 30:00"), markdown)
        XCTAssertFalse(markdown.contains("Where: page 118"), "said already in the heading: " + markdown)
    }

    func testTheMarkdownOfAPaperMarginWithNoCheckpointIsNotHeadedByATime() {
        var live = LiveSession(id: "p", kind: .paper, startedAt: start, endedAt: at(40))
        live.margins = [live.margin(id: "a", text: "Hm", markedAt: at(12), whereNote: "somewhere in the middle")]
        let record = LiveSessionRecord(itemId: "i", session: live, transcript: nil, placed: LiveSessionText.notes(live).placed)
        let markdown = LiveSessionMarkdown.render(record, timeZone: utc)
        XCTAssertTrue(markdown.contains("## 1. Margin\n\nHm\n\nWhere: somewhere in the middle or so.\n\nPosition: 12:00 into the session"), markdown)
    }

    func testTheMarkdownSaysWhenCheckpointsDisagree() {
        var record = paperRecord()
        record.session.margins[0].place = place(.page, 150)
        let markdown = LiveSessionMarkdown.render(record, timeZone: utc)
        XCTAssertTrue(markdown.contains("- Check: You gave page 150 at 10:20 and page 140 at 10:40. That goes backwards, so check one of them."), markdown)
    }

    func testTheSessionNotesNameThePageInTheListenersUnit() {
        let live = paperRecord().session
        let text = LiveSessionText.notes(live).text
        XCTAssertTrue(text.contains("20:00 into the session, at page 118."), text)
        XCTAssertTrue(text.contains("30:00 into the session, at about page 129."), text)
        XCTAssertFalse(text.contains("1:40"), text)
    }

    func testAMeetingWithAPageSaidKeepsItsClockAndShowsThePageAlongside() {
        var live = LiveSession(id: "m", kind: .meeting, startedAt: start, endedAt: at(30), startPositionMs: 0)
        var margin = live.margin(id: "a", text: "see page 12", markedAt: at(10))
        margin.place = place(.page, 12)
        live.margins = [margin]
        let record = LiveSessionRecord(itemId: "i", session: live, transcript: nil, placed: LiveSessionText.notes(live).placed)
        let markdown = LiveSessionMarkdown.render(record, timeZone: utc)
        XCTAssertTrue(markdown.contains("## 1. About 10:00\n\nsee page 12\n\nWhere: page 12.\n"), markdown)
        let notes = LiveSessionText.notes(live).text
        XCTAssertTrue(notes.contains("at about 10:00, you said page 12."), notes)
    }
}
