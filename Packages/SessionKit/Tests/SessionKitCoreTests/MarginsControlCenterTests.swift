import Foundation
import SessionKit
import XCTest

/// The Margins tab and arrival preview list (owner's design 2026-11-17, part of #3216), and "Next Margin".
final class MarginsControlCenterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    private func seedRows() -> [MarginsControlCenter.Row] {
        let own = MarginsControlCenterFixture.ownMargins(createdAt: t0) { "voice/\($0).m4a" }
        let layers = MarginsControlCenterFixture.layers(importedAt: t0)
        let friends = layers.flatMap { MarginsControlCenterFixture.friendMargins(layerId: $0.id, createdAt: t0) { "voice/\($0).m4a" } }
        return MarginsControlCenter.rows(
            itemId: UITestingLaunchSeed.podcastItemId, localMargins: own, layers: layers, importedMargins: friends)
    }

    // MARK: The seed the prototype is captured with

    func testTheSeedHasTwoFriendsAConversationOfFourAndEnoughMarginsToScroll() {
        let rows = seedRows()
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(Set(rows.filter { !$0.isYours }.map(\.senderLabel)), ["Sam", "Rae"])
        // Playback order by thread root; the conversation sits under the listener's Margin at 3:10.
        XCTAssertEqual(rows.map(\.id), [
            "imported-rae-ui-tab-forty",
            "local-own-ui-tab-sleep", "imported-sam-ui-tab-reply", "local-own-ui-tab-answer", "imported-sam-ui-tab-tried",
            "imported-sam-ui-tab-placeholder", "imported-rae-ui-tab-guest", "local-own-ui-tab-walk",
            "imported-sam-ui-tab-naps", "imported-rae-ui-tab-ending",
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 2, 3, 0, 0, 0, 0, 0])
        XCTAssertEqual(rows.compactMap(\.note), [], "every reply's parent is in the seed")
    }

    func testHeardIsFromListeningAndYourOwnAreNeither() {
        let rows = seedRows()
        let hearing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.hearing) })
        XCTAssertEqual(hearing["imported-rae-ui-tab-forty"], .heard)
        XCTAssertEqual(hearing["imported-sam-ui-tab-naps"], .heard)
        XCTAssertEqual(hearing["imported-sam-ui-tab-reply"], .unheard)
        XCTAssertEqual(hearing["local-own-ui-tab-sleep"], .yours)
        XCTAssertEqual(MarginsControlCenter.unheardCount(rows), 5)
        XCTAssertTrue(MarginsControlCenter.opensOnMarginsTab(rows))
    }

    func testOnlyYourOwnMarginsCarryAStar() {
        let starred = seedRows().filter(\.isStarred).map(\.id)
        XCTAssertEqual(starred, ["local-own-ui-tab-walk"])
    }

    func testPlaceholderWordsShowAsComingNotAsTheFriendsWords() {
        let row = seedRows().first { $0.id == "imported-\(MarginsControlCenterFixture.placeholderId)" }
        XCTAssertEqual(row?.words, .coming)
    }

    func testEveryRowQuotesItsLeadInAndStartsTwentySecondsBefore() {
        let rows = seedRows()
        XCTAssertTrue(rows.allSatisfy { $0.leadIn != nil })
        let sleep = rows.first { $0.id == "local-own-ui-tab-sleep" }
        XCTAssertEqual(sleep?.timeMs, 190_000)
        XCTAssertEqual(sleep?.startHereMs, 170_000)
    }

    // MARK: Heard and Autoplay

    func testOnlyListeningToSomeOfAMarginMarksItHeard() {
        XCTAssertTrue(MarginsControlCenter.marksHeard(.listened(ms: 1)))
        XCTAssertTrue(MarginsControlCenter.marksHeard(.listened(ms: 6_000)))
        XCTAssertFalse(MarginsControlCenter.marksHeard(.listened(ms: 0)))
        XCTAssertFalse(MarginsControlCenter.marksHeard(.read))
        XCTAssertFalse(MarginsControlCenter.marksHeard(.openedDetail))
    }

    func testAutoplayUnheardPlaysOnlyFriendsMarginsNotYetHeard() {
        let rows = seedRows()
        XCTAssertEqual(MarginsControlCenter.autoplaying(rows, autoplay: .unheard).map(\.id), [
            "imported-sam-ui-tab-reply", "imported-sam-ui-tab-tried", "imported-sam-ui-tab-placeholder",
            "imported-rae-ui-tab-guest", "imported-rae-ui-tab-ending",
        ])
        XCTAssertEqual(MarginsControlCenter.autoplaying(rows, autoplay: .all).count, rows.count)
        XCTAssertEqual(MarginsControlCenter.autoplaying(rows, autoplay: .none), [])
        let heard = rows.first { $0.hearing == .heard }!
        let yours = rows.first { $0.isYours }!
        XCTAssertEqual(MarginsControlCenter.arrival(for: heard, autoplay: .unheard), .tone)
        XCTAssertEqual(MarginsControlCenter.arrival(for: yours, autoplay: .unheard), .tone)
        XCTAssertEqual(MarginsControlCenter.arrival(for: yours, autoplay: .all), .plays)
        XCTAssertEqual(MarginsControlCenter.Autoplay.allCases, [.unheard, .all, .none])
    }

    func testNextMarginStopsOnlyAtThreadRootsAndPrefersUnheardThreads() {
        let rows = seedRows()
        XCTAssertEqual(MarginsControlCenter.threads(rows).map(\.count), [1, 4, 1, 1, 1, 1, 1])
        // At 13:00 under All the next thread is the walk Margin at 15:30, lead-in from 15:10.
        let all = NextMarginSkip.next(playheadMs: 780_000, rows: rows, autoplay: .all)
        XCTAssertEqual(all, NextMarginSkip(
            marginTimeMs: 930_000, leadInStartMs: 910_000, msUntilMargin: 150_000, action: .seekToLeadIn,
            firstToPlay: .local(MarginsControlCenterFixture.ownWalkId)))
        XCTAssertEqual(all?.countdown, "2:30")
        // Under Unheard it passes the walk (yours) and Sam's heard 19:05 for Rae's unheard 22:40.
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 780_000, rows: rows, autoplay: .unheard)?.marginTimeMs, 1_360_000)
        // At 3:15 the replies at 3:20 to 3:34 are not stops: the next is the 7:45 thread.
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 195_000, rows: rows, autoplay: .all)?.marginTimeMs, 465_000)
    }

    func testLandingOnAThreadPlaysItsFirstUnheardMarginUnlessAutoplayIsAll() {
        let rows = seedRows()
        // At 1:40 the next thread is your 3:10, with Sam's unheard reply at 3:20 under it.
        let unheard = NextMarginSkip.next(playheadMs: 100_000, rows: rows, autoplay: .unheard)
        XCTAssertEqual(unheard?.marginTimeMs, 190_000, "lead-in and countdown are to the thread's first Margin")
        XCTAssertEqual(unheard?.firstToPlay, .imported("sam-ui-tab-reply"))
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 100_000, rows: rows, autoplay: .none)?.firstToPlay,
                       .imported("sam-ui-tab-reply"), "prototype v3: only All starts at the root")
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 100_000, rows: rows, autoplay: .all)?.firstToPlay,
                       .local(MarginsControlCenterFixture.ownFirstId))
    }

    func testAutoplayLabels() {
        XCTAssertEqual(MarginsControlCenter.Autoplay.menuTitle, "Play Margins by themselves")
        XCTAssertEqual(MarginsControlCenter.Autoplay.allCases.map(\.title), ["Unheard Margins", "All Margins", "Off"])
    }

    // MARK: Start controls

    func testRowStartLabelsDifferOnArrivalAndDuringPlayback() {
        XCTAssertEqual(MarginsControlCenter.RowStartContext.arrival.label, "Start with this Margin")
        XCTAssertEqual(MarginsControlCenter.RowStartContext.playback.label, "Jump to this Margin")
        XCTAssertEqual(MarginsControlCenter.startWithUnheardLabel, "Start with unheard Margins")
        XCTAssertEqual(MarginsControlCenter.startFromBeginningLabel, "Start from the beginning")
        XCTAssertEqual(MarginsControlCenter.startFromBeginningMs, 0)
    }

    func testStartWithUnheardGoesToTheLeadInOfTheFirstThreadWithAnUnheardMargin() {
        let rows = seedRows()
        // Rae's 1:40 is heard; the 3:10 thread holds Sam's unheard reply, so it starts at the thread root's lead-in.
        XCTAssertEqual(MarginsControlCenter.startWithUnheardMs(rows), 170_000)
        let heard = rows.filter { $0.hearing != .unheard }
        XCTAssertNil(MarginsControlCenter.startWithUnheardMs(heard))
    }

    // MARK: Opening on the Margins tab

    func testAnItemWhoseFriendsMarginsAreAllHeardOpensOnNow() {
        let rows = seedRows().filter { $0.hearing != .unheard }
        XCTAssertFalse(MarginsControlCenter.opensOnMarginsTab(rows))
        XCTAssertFalse(MarginsControlCenter.opensOnMarginsTab([]))
    }

    // MARK: Words

    func testWordsTable() {
        XCTAssertEqual(MarginsControlCenter.words(nil), .coming)
        XCTAssertEqual(MarginsControlCenter.words(""), .coming)
        XCTAssertEqual(MarginsControlCenter.words("  \n "), .coming)
        XCTAssertEqual(MarginsControlCenter.words("Voice Margin"), .coming)
        XCTAssertEqual(MarginsControlCenter.words(" Voice Margin at 1:02:03 in “Long title”, recorded 1 Jan 2026 "), .coming)
        XCTAssertEqual(MarginsControlCenter.words("Voice Margin at 7:45 is where it turns"), .text("Voice Margin at 7:45 is where it turns"),
                       "a note that only begins like a placeholder is the friend's words")
        XCTAssertEqual(MarginsControlCenter.words("  Great point.  "), .text("Great point."))
        XCTAssertEqual(MarginsControlCenter.words("🙂"), .text("🙂"))
    }

    // MARK: Lead-in excerpt

    func testLeadInExcerptTable() {
        XCTAssertNil(MarginsControlCenter.leadInExcerpt(nil))
        XCTAssertNil(MarginsControlCenter.leadInExcerpt(""))
        XCTAssertNil(MarginsControlCenter.leadInExcerpt(" \n\t "))
        XCTAssertEqual(MarginsControlCenter.leadInExcerpt("  short\n lead   in "), "short lead in")
        let long = String(repeating: "word ", count: 60) + "the end"
        let cut = MarginsControlCenter.leadInExcerpt(long, maxCharacters: 30)
        XCTAssertEqual(cut?.first, "…")
        XCTAssertTrue(cut?.hasSuffix("the end") == true)
        XCTAssertLessThanOrEqual(cut?.count ?? 0, 31)
        XCTAssertFalse(cut?.dropFirst().hasPrefix(" ") == true, "starts at a whole word")
        let oneWord = String(repeating: "x", count: 50)
        XCTAssertEqual(MarginsControlCenter.leadInExcerpt(oneWord, maxCharacters: 10), "…" + String(repeating: "x", count: 10))
        XCTAssertEqual(MarginsControlCenter.leadInExcerpt("café crème", maxCharacters: 80), "café crème")
    }

    // MARK: Next Margin

    func testSkipGoesToTheNextMarginsLeadInAndCountsDownToTheMargin() {
        let skip = NextMarginSkip.next(playheadMs: 60_000, marginTimesMs: [400_000, 190_000, 100_000])
        XCTAssertEqual(skip, NextMarginSkip(
            marginTimeMs: 100_000, leadInStartMs: 80_000, msUntilMargin: 40_000, action: .seekToLeadIn))
        XCTAssertEqual(skip?.countdown, "0:40")
    }

    func testInsideALeadInThePressGoesStraightIntoThatMarginNeverBackNeverPast() {
        // 10 s before the 1:40 Margin, inside its lead-in (1:20 to 1:40).
        let skip = NextMarginSkip.next(playheadMs: 90_000, marginTimesMs: [100_000, 190_000])
        XCTAssertEqual(skip, NextMarginSkip(
            marginTimeMs: 100_000, leadInStartMs: 80_000, msUntilMargin: 10_000, action: .playMargin))
        XCTAssertEqual(skip?.destinationMs, 100_000, "forward into the Margin, not back to 1:20, not on to 3:10")
        // Exactly at the lead-in's start counts as inside it.
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 80_000, marginTimesMs: [100_000])?.action, .playMargin)
        // Exactly at a Margin: that one is behind, the next is ahead.
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 100_000, marginTimesMs: [100_000, 190_000])?.marginTimeMs, 190_000)
        XCTAssertNil(NextMarginSkip.next(playheadMs: 190_000, marginTimesMs: [100_000, 190_000]), "nothing ahead")
    }

    func testAMarginNearTheStartLeadsInFromZero() {
        let skip = NextMarginSkip.next(playheadMs: -1, marginTimesMs: [5_000])
        XCTAssertEqual(skip?.leadInStartMs, 0)
        XCTAssertEqual(skip?.action, .seekToLeadIn)
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 0, marginTimesMs: [5_000])?.destinationMs, 5_000,
                       "at 0:00 the lead-in has begun, so the press goes into the Margin")
        XCTAssertNil(NextMarginSkip.next(playheadMs: 0, marginTimesMs: []))
        XCTAssertNil(NextMarginSkip.next(playheadMs: 0, marginTimesMs: [-4]))
    }

    func testCountdownIsAnMinutesSecondsClockRoundedUp() {
        func clock(_ ms: Int) -> String {
            NextMarginSkip(marginTimeMs: 0, leadInStartMs: 0, msUntilMargin: ms, action: .seekToLeadIn).countdown
        }
        XCTAssertEqual(clock(328_000), "5:28")
        XCTAssertEqual(clock(12_000), "0:12")
        XCTAssertEqual(clock(240_000), "4:00")
        XCTAssertEqual(clock(240_001), "4:01", "rounded up, so it never promises an early arrival")
        XCTAssertEqual(clock(3_725_000), "62:05", "minutes keep counting past an hour")
    }
}
