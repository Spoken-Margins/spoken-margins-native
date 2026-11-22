import Foundation
@testable import SessionKit
import XCTest

/// How the Margins tab and the arrival preview arrange the control centre's rows, and the Autoplay menu's wiring onto
/// the existing auto-play path (owner's prototype v3, part of #3216).
final class MarginsTabListTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    private func seedRows() -> [MarginsControlCenter.Row] {
        let own = MarginsTabUITestSeed.ownMargins(createdAt: t0) { "voice/\($0).m4a" }
        let layers = MarginsTabUITestSeed.layers(importedAt: t0)
        let friends = layers.flatMap { MarginsTabUITestSeed.friendMargins(layerId: $0.id, createdAt: t0) { "voice/\($0).m4a" } }
        return MarginsControlCenter.rows(
            itemId: UITestingLaunchSeed.podcastItemId, localMargins: own, layers: layers, importedMargins: friends)
    }

    // MARK: Threads

    func testRepliesSitUnderTheirThreadAndOnlyDeepRepliesSayWhoTheyAnswer() {
        let threads = MarginsTabList.threads(seedRows())
        XCTAssertEqual(threads.count, 7)
        let conversation = threads[1]
        XCTAssertEqual(conversation.entries.map(\.id), [
            "local-own-ui-tab-sleep", "imported-sam-ui-tab-reply", "local-own-ui-tab-answer", "imported-sam-ui-tab-tried",
        ])
        XCTAssertEqual(conversation.entries.map(\.isReply), [false, true, true, true])
        // Sam's reply sits right under your Margin; your answer is to Sam, Sam's answer to that is to You.
        let you = conversation.entries[0].row.senderLabel
        XCTAssertEqual(conversation.entries.map(\.replyTo), [nil, nil, "Sam", you])
        XCTAssertTrue(threads.filter { $0.id != conversation.id }.allSatisfy { $0.entries.count == 1 })
    }

    func testAListWithoutAThreadStartStillGroups() {
        let replyOnly = Array(seedRows()[2...3])
        XCTAssertEqual(MarginsTabList.threads(replyOnly).count, 1)
        XCTAssertEqual(MarginsTabList.threads([]).count, 0)
    }

    // MARK: Filter

    func testFilterKeepsWholeThreads() {
        let threads = MarginsTabList.threads(seedRows())
        let mine = MarginsTabList.filter(threads, .mine)
        XCTAssertEqual(mine.map(\.id), ["local-own-ui-tab-sleep", "local-own-ui-tab-walk"])
        XCTAssertEqual(mine[0].entries.count, 4, "Sam's replies stay with your Margin")
        let shared = MarginsTabList.filter(threads, .shared)
        XCTAssertFalse(shared.map(\.id).contains("local-own-ui-tab-walk"))
        XCTAssertTrue(shared.map(\.id).contains("local-own-ui-tab-sleep"), "a thread with a friend's reply is shared too")
        XCTAssertEqual(MarginsTabList.filter(threads, .all), threads)
    }

    // MARK: Jump direction

    func testJumpPointsForwardOrBackFromThePlayhead() {
        let row = seedRows().first { $0.id == "imported-rae-ui-tab-guest" }! // 11:20, lead-in from 11:00
        XCTAssertEqual(MarginsTabList.jumpDirection(row, playheadMs: 0), .forward)
        XCTAssertEqual(MarginsTabList.jumpDirection(row, playheadMs: 659_999), .forward)
        XCTAssertEqual(MarginsTabList.jumpDirection(row, playheadMs: 660_000), .backward, "at its lead-in, a jump goes back to it")
        XCTAssertEqual(MarginsTabList.jumpDirection(row, playheadMs: 780_000), .backward)
    }

    // MARK: Arrival preview

    func testArrivalPreviewOnlyBeforeTheListenerHasAPlace() {
        let rows = seedRows()
        XCTAssertTrue(MarginsArrivalPreview.shows(rows, resumePlace: nil, hasFinishedSession: false))
        XCTAssertTrue(MarginsArrivalPreview.shows(rows, resumePlace: Position(charOffset: 0, mediaTimeMs: 0), hasFinishedSession: false))
        XCTAssertFalse(MarginsArrivalPreview.shows(rows, resumePlace: Position(charOffset: 0, mediaTimeMs: 780_000), hasFinishedSession: false), "Continue stays")
        XCTAssertFalse(MarginsArrivalPreview.shows(rows, resumePlace: Position(charOffset: 120), hasFinishedSession: false), "a text place counts")
        XCTAssertFalse(MarginsArrivalPreview.shows(rows, resumePlace: nil, hasFinishedSession: true))
        let allHeardOrMine = rows.filter { $0.hearing != .unheard }
        XCTAssertFalse(MarginsArrivalPreview.shows(allHeardOrMine, resumePlace: nil, hasFinishedSession: false))
    }

    func testWelcomeNamesEveryFriendWithSomethingUnheardAndCountsIt() {
        XCTAssertEqual(MarginsArrivalPreview.welcomeLine(seedRows()), "Sam and Rae left 5 Margins")
        let samOnly = seedRows().filter { $0.senderLabel == "Sam" && $0.hearing == .unheard }
        XCTAssertEqual(MarginsArrivalPreview.welcomeLine(Array(samOnly.prefix(1))), "Sam left 1 Margin")
    }

    /// A friend's label that names nobody reads "A friend" on the row, in "to …" and in the welcome, never a stand-in.
    /// Your own label is shown as it is.
    func testAFriendWhoseFileNamesNobodyReadsAsAFriend() {
        func row(_ id: String, _ label: String, depth: Int = 0, hearing: MarginsControlCenter.Hearing = .unheard)
            -> MarginsControlCenter.Row {
            MarginsControlCenter.Row(
                reference: .imported(id), depth: depth, senderLabel: label, hearing: hearing, words: .coming,
                leadIn: nil, timeMs: 1_000, isStarred: false, note: nil)
        }
        let unnamed = SharedPacketArrival.snapshotSenderLabel(nil)
        let table: [(label: String, shown: String)] = [
            ("Sam", "Sam"), (" Sam ", "Sam"), ("", "A friend"), ("   ", "A friend"), (unnamed, "A friend"),
            (unnamed.uppercased(), "A friend"), ("Someone", "A friend"), ("your  friend", "A friend"),
            ("Zoë", "Zoë"),
        ]
        for (label, shown) in table {
            XCTAssertEqual(row("a", label).shownName, shown, "label \(label.debugDescription)")
        }
        let yours = MarginsControlCenter.Row(
            reference: .local("y"), depth: 0, senderLabel: "You", hearing: .yours, words: .coming,
            leadIn: nil, timeMs: 1_000, isStarred: false, note: nil)
        XCTAssertEqual(yours.shownName, "You")

        let chain = [row("a", unnamed), row("b", "Sam", depth: 1), row("c", "Sam", depth: 2)]
        XCTAssertEqual(MarginsTabList.threads([row("a", "Sam"), row("b", unnamed, depth: 1), row("c", "Sam", depth: 2)])[0]
            .entries.map(\.replyTo), [nil, nil, "A friend"])
        XCTAssertEqual(MarginsArrivalPreview.welcomeLine(chain), "A friend and Sam left 3 Margins")
        XCTAssertEqual(MarginsArrivalPreview.welcomeLine([row("a", ""), row("b", unnamed)]), "A friend left 2 Margins")
    }

    // MARK: Autoplay menu on the existing auto-play path

    func testMenuValueRoundTripsThroughTheLayerSwitchAndThePreference() {
        for autoplay in MarginsControlCenter.Autoplay.allCases {
            let written = MarginsAutoplaySetting.writes(autoplay)
            XCTAssertEqual(MarginsAutoplaySetting.current(autoPlayOn: written.autoPlayOn, includesHeard: written.includesHeard), autoplay)
        }
        XCTAssertEqual(MarginsAutoplaySetting.current(autoPlayOn: false, includesHeard: true), .none)
    }

    func testUnheardGivesAHeardMarginTheToneAndChangesNothingElse() {
        typealias S = MarginsAutoplaySetting
        XCTAssertEqual(S.revealMode(.guided, heard: true, includesHeard: false), .companion)
        XCTAssertEqual(S.revealMode(.guided, heard: false, includesHeard: false), .guided)
        XCTAssertEqual(S.revealMode(.guided, heard: true, includesHeard: true), .guided)
        XCTAssertEqual(S.revealMode(.companion, heard: true, includesHeard: false), .companion)
        XCTAssertEqual(S.revealMode(.fresh, heard: true, includesHeard: false), .fresh)
        XCTAssertNil(S.revealMode(nil, heard: true, includesHeard: false))
        // The prompt style then does what the menu promises, through the one existing rule.
        let heardUnderUnheard = SharedMarginPromptStyle.style(revealMode: S.revealMode(.guided, heard: true, includesHeard: false), arrival: .crossed)
        XCTAssertNil(heardUnderUnheard.autoPlayAfterMs)
        XCTAssertFalse(heardUnderUnheard.pausesSource)
    }

    func testMenuShortWords() {
        XCTAssertEqual(MarginsControlCenter.Autoplay.allCases.map(\.shortTitle), ["Unheard", "All", "Off"])
    }
}
