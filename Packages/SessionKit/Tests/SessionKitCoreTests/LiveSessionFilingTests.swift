import Foundation
import XCTest
@testable import SessionKit

/// #2487 slice 1a: the filing rule (`docs/design/live-sessions/DESIGN.md` section 4 point 6), row by row, with the
/// neighbours of each row: exact boundaries, a clock two minutes off, overlapping sessions, deleted ids and duplicates.
final class LiveSessionFilingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ms = 0.001

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A meeting 0–3600 s (ended), a lecture running since 7200 s, and the time now is 9000 s.
    private var meeting: LiveSessionFiling.Candidate { .init(id: "meet", startedAt: at(0), endedAt: at(3_600), marginIds: ["m-old"]) }
    private var running: LiveSessionFiling.Candidate { .init(id: "live", startedAt: at(7_200), endedAt: nil) }
    private var now: Date { at(9_000) }

    private func decide(
        _ seconds: TimeInterval, id: String = "new", names: String? = nil, offset: TimeInterval? = nil, allowsPlayer: Bool = true,
        sessions: [LiveSessionFiling.Candidate]? = nil, deletions: LiveSessionFiling.Deletions = .init(),
        player: [LiveSessionFiling.PlayerRun] = [], now: Date? = nil
    ) -> LiveSessionFiling.Decision {
        LiveSessionFiling.decide(
            .init(marginId: id, markedAt: at(seconds), clockOffset: offset, sessionId: names, allowsPlayerItem: allowsPlayer),
            sessions: sessions ?? [meeting], deletions: deletions, playerRuns: player, now: now ?? self.now
        )
    }

    // MARK: 1. The span that holds it

    func testInsideAnEndedSessionsSpanFilesThere() {
        XCTAssertEqual(decide(1_800), .session(id: "meet", placement: .withinSpan))
    }

    func testTheSpansEdgesAreInside() {
        XCTAssertEqual(decide(0), .session(id: "meet", placement: .withinSpan))
        XCTAssertEqual(decide(3_600), .session(id: "meet", placement: .withinSpan))
    }

    func testJustOutsideTheSpanIsNotInIt() {
        XCTAssertEqual(decide(-ms), .newQuick)
        XCTAssertEqual(decide(3_600 + ms), .newQuick)
    }

    func testARunningSessionHoldsEverythingFromItsStart() {
        XCTAssertEqual(decide(7_200, sessions: [meeting, running]), .session(id: "live", placement: .withinSpan))
        XCTAssertEqual(decide(8_999, sessions: [meeting, running]), .session(id: "live", placement: .withinSpan))
        // A Margin stamped a little after "now" (the Watch's clock runs ahead) is still in the running session.
        XCTAssertEqual(decide(9_030, sessions: [meeting, running]), .session(id: "live", placement: .withinSpan))
        XCTAssertEqual(decide(7_200 - 1, sessions: [meeting, running]), .newQuick)
    }

    func testOverlappingSpansPickTheLaterStart() {
        let long = LiveSessionFiling.Candidate(id: "long", startedAt: at(0), endedAt: nil)
        let short = LiveSessionFiling.Candidate(id: "short", startedAt: at(100), endedAt: at(200))
        XCTAssertEqual(decide(150, sessions: [long, short]), .session(id: "short", placement: .withinSpan))
        XCTAssertEqual(decide(250, sessions: [long, short]), .session(id: "long", placement: .withinSpan))
    }

    // MARK: The clock

    func testAWatchClockTwoMinutesAheadIsCorrectedWhenMeasured() {
        // Taken one minute before the end by the phone's clock; the Watch, two minutes fast, stamped it a minute after.
        XCTAssertEqual(decide(3_660, offset: 120), .session(id: "meet", placement: .withinSpan))
        // Unmeasured (today's Watch), the raw time is all there is.
        XCTAssertEqual(decide(3_660), .newQuick)
    }

    func testAWatchClockTwoMinutesBehindIsCorrectedWhenMeasured() {
        XCTAssertEqual(decide(-60, offset: -120), .session(id: "meet", placement: .withinSpan))
        XCTAssertEqual(decide(-60), .newQuick)
    }

    // MARK: 2. The session it names, within 30 minutes of its end

    func testANamedSessionTakesAMarginUpTo30MinutesAfterItsEnd() {
        XCTAssertEqual(decide(3_600 + 1, names: "meet"), .session(id: "meet", placement: .afterEnd))
        XCTAssertEqual(decide(3_600 + 1_800, names: "meet"), .session(id: "meet", placement: .afterEnd))
    }

    /// Second review: with no limit a Watch showing old state filed tomorrow's Margin into yesterday's meeting.
    func testPast30MinutesTheNamedSessionNoLongerTakesIt() {
        XCTAssertEqual(decide(3_600 + 1_800 + ms, names: "meet"), .newQuick)
        XCTAssertEqual(decide(3_600 + 86_400, names: "meet", now: at(3_600 + 86_400)), .newQuick)
    }

    func testOnlyAMarginThatNamesTheSessionGetsTheAfterEndWindow() {
        XCTAssertEqual(decide(3_600 + 60), .newQuick)
    }

    func testANamedRunningSessionTakesItEvenStampedBeforeItsStart() {
        XCTAssertEqual(decide(7_100, names: "live", sessions: [meeting, running]), .session(id: "live", placement: .withinSpan))
    }

    func testANamedEndedSessionDoesNotTakeAMarginFromBeforeItsStart() {
        XCTAssertEqual(decide(-600, names: "meet"), .newQuick)
    }

    func testTheSpanThatHoldsItOutranksTheSessionItNames() {
        XCTAssertEqual(decide(7_300, names: "meet", sessions: [meeting, running]), .session(id: "live", placement: .withinSpan))
    }

    // MARK: 3. A session id the phone has never seen

    func testAnUnknownNamedSessionBecomesANewSessionWithThatId() {
        XCTAssertEqual(decide(5_000, names: "watch-lecture"), .newNamedSession(id: "watch-lecture"))
    }

    func testANamedQuickSessionIsJoined() {
        let quick = LiveSessionFiling.Candidate(id: "quick-1", startedAt: at(5_000), endedAt: at(5_000), isQuick: true)
        XCTAssertEqual(decide(8_000, names: "quick-1", sessions: [meeting, quick]), .joinQuick(id: "quick-1"))
    }

    // MARK: Deleted and duplicate ids

    func testADeletedMarginIdIsRefusedEvenInsideASpan() {
        XCTAssertEqual(decide(1_800, id: "gone", deletions: .init(marginIds: ["gone"])), .rejected(.marginDeleted))
    }

    func testADeletedSessionRefusesAMarginThatNamesIt() {
        let deleted = LiveSessionFiling.Deletions(sessions: [.init(id: "old", startedAt: at(4_000), endedAt: at(4_100))])
        XCTAssertEqual(decide(9_000, names: "old", deletions: deleted), .rejected(.sessionDeleted))
    }

    func testAMarginOnlyInADeletedSessionsSpanIsRefused() {
        let deleted = LiveSessionFiling.Deletions(sessions: [.init(id: "old", startedAt: at(4_000), endedAt: at(4_100))])
        XCTAssertEqual(decide(4_050, deletions: deleted), .rejected(.sessionDeleted))
        XCTAssertEqual(decide(4_100 + ms, deletions: deleted), .newQuick)
        // A live session over the same time still takes it.
        let over = LiveSessionFiling.Candidate(id: "over", startedAt: at(4_000), endedAt: at(4_200))
        XCTAssertEqual(decide(4_050, sessions: [over], deletions: deleted), .session(id: "over", placement: .withinSpan))
    }

    func testADuplicateIdInAnEndedSessionIsAlreadyFiled() {
        // Its time now falls in no session, and it would otherwise make a quick session: the id wins.
        XCTAssertEqual(decide(50_000, id: "m-old"), .alreadyFiled(sessionId: "meet"))
    }

    func testADuplicateIdInASavedSessionIsAlreadyFiled() {
        let saved = LiveSessionFiling.Candidate(id: "saved", startedAt: at(0), endedAt: at(10), isSaved: true, marginIds: ["s1"])
        XCTAssertEqual(decide(5, id: "s1", sessions: [saved]), .alreadyFiled(sessionId: "saved"))
    }

    func testASavedSessionTakesNoNewMargins() {
        let saved = LiveSessionFiling.Candidate(id: "saved", startedAt: at(0), endedAt: at(3_600), isSaved: true)
        XCTAssertEqual(decide(1_800, sessions: [saved]), .newQuick)
        XCTAssertEqual(decide(3_700, names: "saved", sessions: [saved]), .newQuick)
    }

    // MARK: 4. Our own player

    private let episode = LiveSessionFiling.PlayerRun(itemId: "ep", startedAt: Date(timeIntervalSince1970: 1_800_010_000),
                                                      endedAt: Date(timeIntervalSince1970: 1_800_010_600), startPositionMs: 60_000, rate: 1.5)

    func testWithNoSessionAMarginGoesOntoThePlayingItemAtItsPosition() {
        XCTAssertEqual(decide(10_100, player: [episode], now: at(11_000)), .playerItem(itemId: "ep", positionMs: 60_000 + 150_000))
        XCTAssertEqual(decide(10_000, player: [episode], now: at(11_000)), .playerItem(itemId: "ep", positionMs: 60_000))
        XCTAssertEqual(decide(10_600, player: [episode], now: at(11_000)), .playerItem(itemId: "ep", positionMs: 60_000 + 900_000))
        XCTAssertEqual(decide(10_600 + 1, player: [episode], now: at(11_000)), .newQuick)
    }

    func testASessionOutranksThePlayer() {
        let over = LiveSessionFiling.Candidate(id: "over", startedAt: at(10_000), endedAt: nil)
        XCTAssertEqual(decide(10_100, sessions: [over], player: [episode], now: at(11_000)), .session(id: "over", placement: .withinSpan))
    }

    func testThePlayerOutranksAQuickSession() {
        let quick = LiveSessionFiling.Candidate(id: "quick-1", startedAt: at(10_050), endedAt: at(10_050), isQuick: true)
        XCTAssertEqual(decide(10_100, sessions: [quick], player: [episode], now: at(11_000)), .playerItem(itemId: "ep", positionMs: 210_000))
    }

    func testAMarginThatMayNotGoOnTheItemSkipsThePlayer() {
        XCTAssertEqual(decide(10_100, allowsPlayer: false, player: [episode], now: at(11_000)), .newQuick)
    }

    // MARK: 5. Quick sessions

    private func quick(_ id: String, _ first: TimeInterval, _ last: TimeInterval) -> LiveSessionFiling.Candidate {
        .init(id: id, startedAt: at(first), endedAt: at(last), isQuick: true)
    }

    func testAQuickSessionTakesMarginsWithin30MinutesOfItsLast() {
        let q = quick("q", 20_000, 20_100)
        XCTAssertEqual(decide(20_100 + 1_800, sessions: [q], now: at(30_000)), .joinQuick(id: "q"))
        XCTAssertEqual(decide(20_100 + 1_800 + ms, sessions: [q], now: at(30_000)), .newQuick)
        XCTAssertEqual(decide(20_050, sessions: [q], now: at(30_000)), .joinQuick(id: "q"))
        // A late copy from before its first Margin joins too, within 30 minutes.
        XCTAssertEqual(decide(20_000 - 1_800, sessions: [q], now: at(30_000)), .joinQuick(id: "q"))
        XCTAssertEqual(decide(20_000 - 1_800 - ms, sessions: [q], now: at(30_000)), .newQuick)
    }

    func testBetweenTwoQuickSessionsTheNearerOneTakesIt() {
        let early = quick("early", 20_000, 20_000)
        let late = quick("late", 21_000, 21_000)
        XCTAssertEqual(decide(20_400, sessions: [early, late], now: at(30_000)), .joinQuick(id: "early"))
        XCTAssertEqual(decide(20_600, sessions: [early, late], now: at(30_000)), .joinQuick(id: "late"))
        XCTAssertEqual(decide(20_500, sessions: [early, late], now: at(30_000)), .joinQuick(id: "late"))
    }

    func testASavedQuickSessionTakesNoMore() {
        var q = quick("q", 20_000, 20_100)
        q.isSaved = true
        XCTAssertEqual(decide(20_200, sessions: [q], now: at(30_000)), .newQuick)
    }

    func testWithNothingAtAllItMakesAQuickSession() {
        XCTAssertEqual(decide(1_800, sessions: []), .newQuick)
    }

    // MARK: Keeping quick sessions tidy

    private func margin(_ id: String, _ seconds: TimeInterval) -> LiveSessionMargin {
        LiveSessionMargin(id: id, text: id, markedAt: at(seconds))
    }

    private func quickSession(_ id: String, _ margins: [LiveSessionMargin]) -> LiveSession {
        var session = LiveSessionFiling.quickSession(id: id, holding: margins[0])
        for margin in margins.dropFirst() { session.add(margin) }
        return session
    }

    func testOverlappingQuickSessionsMerge() {
        let phone = quickSession("phone", [margin("p1", 100), margin("p2", 400)])
        let watch = quickSession("watch", [margin("w1", 300), margin("w2", 700)])
        let (kept, removed) = LiveSessionFiling.tidy([watch, phone], now: at(1_000))
        XCTAssertEqual(removed, ["watch"])
        XCTAssertEqual(kept.map(\.id), ["phone"])
        XCTAssertEqual(kept[0].margins.map(\.id), ["p1", "w1", "p2", "w2"])
        XCTAssertEqual(kept[0].startedAt, at(100))
        XCTAssertEqual(kept[0].endedAt, at(700))
        XCTAssertEqual(kept[0].margins.map(\.sessionOffsetMs), [0, 200_000, 300_000, 600_000])
    }

    func testQuickSessionsThatOnlyTouchMergeButNearbyOnesDoNot() {
        let touching = LiveSessionFiling.tidy([quickSession("a", [margin("a1", 0), margin("a2", 100)]), quickSession("b", [margin("b1", 100)])], now: at(1_000))
        XCTAssertEqual(touching.removedIds, ["b"])
        let apart = LiveSessionFiling.tidy([quickSession("a", [margin("a1", 0)]), quickSession("b", [margin("b1", 100 + ms)])], now: at(1_000))
        XCTAssertEqual(apart.removedIds, [])
        XCTAssertEqual(apart.sessions.count, 2)
    }

    func testAMarginInBothQuickSessionsIsKeptOnce() {
        let (kept, _) = LiveSessionFiling.tidy([quickSession("a", [margin("x", 0), margin("y", 50)]), quickSession("b", [margin("y", 50)])], now: at(1_000))
        XCTAssertEqual(kept.flatMap(\.margins).map(\.id), ["x", "y"])
    }

    func testQuickMarginsANamedSessionCoversMoveIntoIt() {
        let watchQuick = quickSession("quick", [margin("w1", 150), margin("w2", 900)])
        let meeting = LiveSession(id: "meet", startedAt: at(100), endedAt: at(500))
        let (kept, removed) = LiveSessionFiling.tidy([meeting, watchQuick], now: at(1_000))
        XCTAssertEqual(removed, [])
        let named = try? XCTUnwrap(kept.first { $0.id == "meet" })
        XCTAssertEqual(named?.margins.map(\.id), ["w1"])
        XCTAssertEqual(named?.margins.first?.filingNote, LiveSessionFiling.movedFromQuickNote)
        XCTAssertEqual(named?.margins.first?.sessionOffsetMs, 50_000)
        let left = kept.first { $0.id == "quick" }
        XCTAssertEqual(left?.margins.map(\.id), ["w2"])
        XCTAssertEqual(left?.startedAt, at(900))
    }

    func testAQuickSessionEmptiedIntoANamedSessionIsRemoved() {
        let (kept, removed) = LiveSessionFiling.tidy([LiveSession(id: "meet", startedAt: at(0), endedAt: nil), quickSession("quick", [margin("w1", 10)])], now: at(1_000))
        XCTAssertEqual(removed, ["quick"])
        XCTAssertEqual(kept.map(\.id), ["meet"])
    }

    func testSavedSessionsAreLeftAlone() {
        var saved = quickSession("saved", [margin("s1", 0), margin("s2", 100)])
        saved.savedItemId = "item-1"
        var savedMeeting = LiveSession(id: "meet", startedAt: at(0), endedAt: at(200))
        savedMeeting.savedItemId = "item-2"
        let other = quickSession("other", [margin("o1", 50)])
        let (kept, removed) = LiveSessionFiling.tidy([saved, savedMeeting, other], now: at(1_000))
        XCTAssertEqual(removed, [])
        XCTAssertEqual(Set(kept.map(\.id)), ["saved", "meet", "other"])
        XCTAssertEqual(kept.first { $0.id == "other" }?.margins.map(\.id), ["o1"])
    }
}
