import XCTest
@testable import SessionKit

/// #3788: which pinned button can start, and the tap a friend makes before it can. Table tests over the Design's
/// starting states (first read, returning, finished, already heard, web packet, wrong episode, slow or failing download).
final class FriendArrivalStartTests: XCTestCase {
    private typealias Start = FriendArrivalStart
    private let item = "item"

    // MARK: Ready or waiting

    func testEachButtonIsReadyOnlyWhatItNeedsIsHere() {
        struct Row {
            let name: String
            let canStart: Bool
            var failed = false
            let first: Start.FirstMarginAudio?
            let play: Start.Readiness
            let skip: Start.Readiness
        }
        let rows = [
            Row(name: "everything here", canStart: true, first: .recording(onPhone: true), play: .ready, skip: .ready),
            Row(name: "episode still downloading", canStart: false, first: .recording(onPhone: true), play: .waiting, skip: .ready),
            Row(name: "recording's file not here yet", canStart: true, first: .recording(onPhone: false), play: .ready, skip: .waiting),
            Row(name: "nothing here yet", canStart: false, first: .recording(onPhone: false), play: .waiting, skip: .waiting),
            Row(name: "written Margin, reading made", canStart: true, first: .reading(isReady: true), play: .ready, skip: .ready),
            Row(name: "written Margin, reading not made", canStart: true, first: .reading(isReady: false), play: .ready, skip: .waiting),
            Row(name: "download failed", canStart: false, failed: true, first: .recording(onPhone: true), play: .failed, skip: .ready),
            Row(name: "failed, though it can start from a stream", canStart: true, failed: true, first: .recording(onPhone: true), play: .ready, skip: .ready),
            Row(name: "first Margin can't play: the review says why", canStart: true, first: .unavailable, play: .ready, skip: .ready),
            Row(name: "first Margin can't play, episode waiting", canStart: false, first: .unavailable, play: .waiting, skip: .ready),
            Row(name: "no Margin waits", canStart: false, first: nil, play: .waiting, skip: .ready)
        ]
        for row in rows {
            let start = Start(episodeCanStart: row.canStart, episodeFailed: row.failed, firstMargin: row.first)
            XCTAssertEqual(start.play, row.play, "play: \(row.name)")
            XCTAssertEqual(start.skip, row.skip, "skip: \(row.name)")
            XCTAssertEqual(start.readiness(of: .play), row.play, row.name)
            XCTAssertEqual(start.readiness(of: .skip), row.skip, row.name)
        }
    }

    // MARK: A tap before it can start

    private let slowEpisode = Start(episodeCanStart: false, firstMargin: .recording(onPhone: true))
    private let allHere = Start(episodeCanStart: true, firstMargin: .recording(onPhone: true))

    func testATapThatCanRunRunsAndKeepsNothing() {
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.tap(.play, itemId: item, start: allHere), .start(.play))
        XCTAssertNil(kept.choice)
        XCTAssertNil(kept.waitingLine)
        XCTAssertEqual(kept.tap(.skip, itemId: item, start: allHere), .start(.skip))
        XCTAssertNil(kept.waitingLine)
    }

    func testATapTooEarlyIsKeptWithTheLineAndRunsByItselfWhenReady() {
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.tap(.play, itemId: item, start: slowEpisode), .kept(announce: true))
        XCTAssertEqual(kept.waitingLine, "Getting the episode ready. It starts by itself.")
        XCTAssertEqual(kept.update(itemId: item, start: slowEpisode), .kept(announce: false), "still waiting")
        XCTAssertEqual(kept.waitingLine, Start.waitingLine)
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .start(.play), "no second tap")
        XCTAssertNil(kept.waitingLine, "the line goes once it starts")
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle, "and it runs once")
    }

    func testTheSameButtonTwiceChangesNothingAndAnnouncesOnce() {
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.tap(.play, itemId: item, start: slowEpisode), .kept(announce: true))
        XCTAssertEqual(kept.tap(.play, itemId: item, start: slowEpisode), .kept(announce: false))
        XCTAssertEqual(kept.choice, .play)
    }

    func testTheOtherButtonSwitchesTheKeptChoiceWithoutAnnouncingAgain() {
        let both = Start(episodeCanStart: false, firstMargin: .reading(isReady: false))
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.tap(.play, itemId: item, start: both), .kept(announce: true))
        XCTAssertEqual(kept.tap(.skip, itemId: item, start: both), .kept(announce: false))
        XCTAssertEqual(kept.choice, .skip)
        // The reading lands first: Skip runs, and Play is not run later.
        let readingMade = Start(episodeCanStart: false, firstMargin: .reading(isReady: true))
        XCTAssertEqual(kept.update(itemId: item, start: readingMade), .start(.skip))
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle)
    }

    func testATapOnAReadyButtonDropsAKeptTapOnTheOther() {
        let skipReadyPlayNot = Start(episodeCanStart: false, firstMargin: .recording(onPhone: true))
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.tap(.play, itemId: item, start: skipReadyPlayNot), .kept(announce: true))
        XCTAssertEqual(kept.tap(.skip, itemId: item, start: skipReadyPlayNot), .start(.skip))
        XCTAssertNil(kept.choice, "Play must not start after Skip did")
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle)
    }

    func testLeavingOrSwitchingTheItemCancelsTheKeptTap() {
        var kept = KeptFriendStart()
        _ = kept.tap(.play, itemId: item, start: slowEpisode)
        XCTAssertEqual(kept.update(itemId: "another", start: allHere), .idle, "the screen switched to another item")
        XCTAssertNil(kept.waitingLine)
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle)

        _ = kept.tap(.skip, itemId: item, start: Start(episodeCanStart: true, firstMargin: .recording(onPhone: false)))
        kept.cancel()
        XCTAssertNil(kept.waitingLine, "the listener left the screen")
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle)
    }

    func testATapOnAnotherItemStartsAFreshKeptTap() {
        var kept = KeptFriendStart()
        _ = kept.tap(.play, itemId: "first", start: slowEpisode)
        XCTAssertEqual(kept.tap(.play, itemId: "second", start: slowEpisode), .kept(announce: true))
        XCTAssertEqual(kept.itemId, "second")
        XCTAssertEqual(kept.update(itemId: "first", start: allHere), .idle)
    }

    func testAFailedDownloadTakesTheLineAwayAndRunsNothing() {
        let failed = Start(episodeCanStart: false, episodeFailed: true, firstMargin: .recording(onPhone: true))
        var kept = KeptFriendStart()
        _ = kept.tap(.play, itemId: item, start: slowEpisode)
        XCTAssertEqual(kept.update(itemId: item, start: failed), .idle)
        XCTAssertNil(kept.waitingLine, "the failure card shows instead")
        XCTAssertEqual(kept.tap(.play, itemId: item, start: failed), .idle, "a tap on a failed download keeps nothing")
        XCTAssertNil(kept.choice)
        // Skip never waits on the episode, so a failed download leaves its kept tap alone.
        let skipWaits = Start(episodeCanStart: false, episodeFailed: true, firstMargin: .reading(isReady: false))
        XCTAssertEqual(kept.tap(.skip, itemId: item, start: skipWaits), .kept(announce: true))
        XCTAssertEqual(kept.update(itemId: item, start: skipWaits), .kept(announce: false))
    }

    func testAnUpdateWithNothingKeptDoesNothing() {
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle)
        XCTAssertEqual(kept, KeptFriendStart())
    }

    // MARK: The Design's starting states, on the intro and the two choices

    /// A packet just opened on an episode that isn't downloaded gives the intro and both choices on the first read,
    /// whatever the listener's history with the item: first run, returning, finished, marked complete, 99%.
    func testTheIntroAndBothChoicesExistOnTheFirstReadInEveryStartingState() throws {
        let packet = SharedMarginReview.entries(
            layers: [layer(finishedPass: false)],
            records: ["layer": [margin(id: "web", sender: 134_000), margin(id: "none", sender: nil)]])
        let waiting = packet.map(\.waitingMargin)
        XCTAssertEqual(waiting.count, 2)
        for finished in [false, true] {
            for continuing in [false, true] {
                for preparing in [false, true] {
                    let state = "finished \(finished), continuing \(continuing), preparing \(preparing)"
                    let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: waiting), state)
                    XCTAssertEqual(intro.senderLine, "From Cole", state)
                    let choices = ItemListeningChoices(
                        unheardFriendMargins: waiting, hasFinishedSession: finished,
                        hasContinuationSession: continuing, isPreparingAudio: preparing)
                    XCTAssertEqual(choices.primaryTitle, "Play", state)
                    XCTAssertTrue(choices.secondaryTitle?.hasPrefix("Skip to Cole's Margins") == true, state)
                }
            }
        }
    }

    func testAMarginBehindTheListenersPlaceStillMakesTheIntro() throws {
        var unheard = margin(id: "behind", sender: 5_000)
        unheard.firstHeardAt = nil
        let entries = SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [unheard]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)))
        var heard = unheard
        heard.firstHeardAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [heard]]).isEmpty)
    }

    func testAWrongEpisodeGivesNoIntroAndNoSkipMinutes() {
        var other = layer(finishedPass: false)
        other.sourceResolutionStatus = .wrongSource
        let entries = SharedMarginReview.entries(layers: [other], records: ["layer": [margin(id: "m", sender: 5_000)]])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)))
        let choices = ItemListeningChoices(
            unheardFriendMargins: entries.map(\.waitingMargin), hasFinishedSession: false,
            hasContinuationSession: false, isPreparingAudio: false)
        XCTAssertNil(choices.secondaryTitle, "no Skip button, so no minutes")
    }

    func testSkipOrderPutsTheEarliestMarginFirst() {
        // `FirstMarginAudio` is read from the first of these, so the order is the screen's input.
        let late = margin(id: "late", sender: 90_000)
        let early = margin(id: "early", sender: 5_000)
        let entries = SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [late, early]])
        XCTAssertEqual(entries.map(\.interjection.id), ["early", "late"])
    }

    // MARK: Helpers

    private func layer(finishedPass: Bool) -> ImportedCommentaryLayer {
        var value = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "d", packageId: "p",
                                            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                            displayLabel: "Cole", importedAt: Date(timeIntervalSince1970: 0),
                                            sourceResolutionStatus: .resolved, isEnabled: true)
        if finishedPass { value.resolvedRecipientEditionSHA256 = "digest" }
        return value
    }

    private func margin(id: String, sender: Int?) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer", packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: sender),
            approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: .unresolved, localMediaTimeMs: nil, isAmbiguous: false))
    }
}
