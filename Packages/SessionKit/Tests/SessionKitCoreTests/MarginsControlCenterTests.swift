import Foundation
import SessionKit
import XCTest

/// The Margins tab and arrival preview list (owner's design 2026-11-17, part of #3216), and "Skip to next Margin".
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

    func testSkipStepsThroughEveryPlacedMarginRepliesIncluded() {
        let rows = seedRows()
        let times = MarginsControlCenter.skipTimes(rows)
        XCTAssertEqual(times.count, 10)
        // At 13:00 (the fixture's place) the next is the walk Margin at 15:30, lead-in from 15:10.
        let skip = NextMarginSkip.next(playheadMs: 780_000, marginTimesMs: times)
        XCTAssertEqual(skip, NextMarginSkip(marginTimeMs: 930_000, leadInStartMs: 910_000, msUntilMargin: 150_000))
        XCTAssertEqual(skip?.countdown, "in 3 min")
        // Inside the conversation: at 3:15 the 3:32 and 3:34 Margins' lead-ins are behind, so it goes on to 7:45.
        XCTAssertEqual(NextMarginSkip.next(playheadMs: 195_000, marginTimesMs: times)?.marginTimeMs, 465_000)
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

    // MARK: Skip to next Margin

    func testSkipGoesToTheNextMarginsLeadInAndCountsDownToTheMargin() {
        let skip = NextMarginSkip.next(playheadMs: 60_000, marginTimesMs: [400_000, 190_000, 100_000])
        XCTAssertEqual(skip, NextMarginSkip(marginTimeMs: 100_000, leadInStartMs: 80_000, msUntilMargin: 40_000))
        XCTAssertEqual(skip?.countdown, "in under 1 min")
    }

    func testInsideALeadInTheSkipGoesOnToTheMarginAfterNeverBack() {
        let skip = NextMarginSkip.next(playheadMs: 90_000, marginTimesMs: [100_000, 190_000])
        XCTAssertEqual(skip?.marginTimeMs, 190_000)
        XCTAssertEqual(skip?.leadInStartMs, 170_000)
        XCTAssertNil(NextMarginSkip.next(playheadMs: 180_000, marginTimesMs: [100_000, 190_000]), "nothing ahead of the lead-in")
    }

    func testAMarginNearTheStartLeadsInFromZero() {
        let skip = NextMarginSkip.next(playheadMs: -1, marginTimesMs: [5_000])
        XCTAssertEqual(skip?.leadInStartMs, 0)
        XCTAssertNil(NextMarginSkip.next(playheadMs: 0, marginTimesMs: [5_000]), "already at that lead-in")
        XCTAssertNil(NextMarginSkip.next(playheadMs: 0, marginTimesMs: []))
        XCTAssertNil(NextMarginSkip.next(playheadMs: 0, marginTimesMs: [-4]))
    }

    func testCountdownWordsMatchTheCard() {
        XCTAssertEqual(NextMarginSkip(marginTimeMs: 0, leadInStartMs: 0, msUntilMargin: 12_000).countdown, "in 12 sec")
        XCTAssertEqual(NextMarginSkip(marginTimeMs: 0, leadInStartMs: 0, msUntilMargin: 240_000).countdown, "in 4 min")
        XCTAssertEqual(NextMarginSkip(marginTimeMs: 0, leadInStartMs: 0, msUntilMargin: 241_000).countdown, "in 5 min")
    }
}
