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

    func testATapOnAFailedPlayLeavesAKeptSkipAlone() {
        let failedPlayWaitingSkip = Start(episodeCanStart: false, episodeFailed: true, firstMargin: .reading(isReady: false))
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.tap(.skip, itemId: item, start: failedPlayWaitingSkip), .kept(announce: true))
        XCTAssertEqual(kept.tap(.play, itemId: item, start: failedPlayWaitingSkip), .kept(announce: false))
        XCTAssertEqual(kept.choice, .skip, "Play had nothing to keep; Skip is still waiting for its reading")
        XCTAssertEqual(kept.update(itemId: item, start: Start(episodeCanStart: false, episodeFailed: true, firstMargin: .reading(isReady: true))), .start(.skip))
        // A kept Play on a different item is not Skip's to keep.
        var other = KeptFriendStart()
        _ = other.tap(.skip, itemId: "first", start: failedPlayWaitingSkip)
        XCTAssertEqual(other.tap(.play, itemId: "second", start: failedPlayWaitingSkip), .idle)
        XCTAssertNil(other.choice)
    }

    func testAnUpdateWithNothingKeptDoesNothing() {
        var kept = KeptFriendStart()
        XCTAssertEqual(kept.update(itemId: item, start: allHere), .idle)
        XCTAssertEqual(kept, KeptFriendStart())
    }

    // MARK: The item screen's facts

    func testTheItemScreensFactsMapToTheStartRule() {
        let wanted: [(NativeTextStartupAudioState, Start.Readiness)] = [
            (.notRequired, .ready), (.ready, .ready), (.paused, .ready),
            (.waiting, .waiting), (.preparing, .waiting), (.failed, .failed)
        ]
        for (state, play) in wanted {
            XCTAssertEqual(Start(startupAudio: state, firstMargin: .recording(onPhone: true)).play, play, "\(state)")
        }
    }

    func testTheFirstMarginsAudioMapsFromTheOneResolver() {
        let url = URL(fileURLWithPath: "/tmp/a.m4a")
        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Words", itemId: "item")
        let cases: [(SharedMarginAudio, Start.FirstMarginAudio, Start.Readiness)] = [
            (.voiceFile(url), .recording(onPhone: true), .ready),
            (.readingReady(reading, file: url), .reading(isReady: true), .ready),
            (.readingRendering(reading, file: url), .reading(isReady: false), .waiting),
            (.cannotBeRead, .unavailable, .ready)
        ]
        let long = WrittenMarginReading(intro: "Cole wrote:", text: String(repeating: "a", count: 2_000), itemId: "item")
        XCTAssertEqual(Start.FirstMarginAudio(.readingRendering(long, file: url)), .reading(isReady: true),
                       "a long note is not rendered ahead, so it is not waited for here")
        for (audio, mapped, skip) in cases {
            XCTAssertEqual(Start.FirstMarginAudio(audio), mapped)
            XCTAssertEqual(Start(episodeCanStart: true, firstMargin: mapped).skip, skip)
        }
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
