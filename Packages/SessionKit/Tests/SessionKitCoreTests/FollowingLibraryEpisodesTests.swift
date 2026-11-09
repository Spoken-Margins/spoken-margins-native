import XCTest
@testable import SessionKit

/// Which Library item a followed episode became, and whether it is finished (the Following row's preview rule).
final class FollowingLibraryEpisodesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ id: String, page: String? = nil, audio: String? = nil, state: FeedEntryState = .imported) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: "show", canonicalURL: page ?? "https://example.com/\(id)", audioURL: audio,
            title: id, state: state)
    }

    private func item(
        _ id: String, reference: String? = nil, media: String? = nil, completedAt: Date? = nil,
        deletedAt: Date? = nil, createdAt: Date? = nil
    ) -> LibraryItemSummary {
        LibraryItemSummary(
            id: id, title: id, mediaType: "article", status: "ready", externalReference: reference,
            media: media.map { ItemMedia(sourceType: .remoteStream, url: $0) }, deletedAt: deletedAt, createdAt: createdAt,
            sourceCompletedAt: completedAt, hasListenableText: true, textCharacterCount: 100)
    }

    private func session(_ itemId: String, percent: Int, status: String = "in_progress", phase: SessionPhase = .itemPlayback) -> Session {
        Session(
            id: "s-\(itemId)-\(percent)", itemId: itemId, status: status, phase: phase, currentTargetType: .transcriptBackedMedia,
            currentTargetId: itemId, position: Position(), completionPercent: percent, playbackRate: 1)
    }

    func testAnArticleMatchesByItsPageAddressAndIsFinishedOnlyWhenListenedThrough() {
        let entries = [entry("e1"), entry("e2")]
        let items = [item("i1", reference: "https://example.com/e1"), item("i2", reference: "https://example.com/e2")]
        let result = FollowingLibraryEpisodes.resolve(
            entries: entries, items: items, sessions: [session("i1", percent: 40), session("i2", percent: 100, status: "finished", phase: .finished)])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "i1", isFinished: false))
        XCTAssertEqual(result["e2"], FollowingLibraryEpisode(itemID: "i2", isFinished: true))
    }

    func testAnItemMarkedCompleteByHandIsFinishedWithNoSession() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")], items: [item("i1", reference: "https://example.com/e1", completedAt: t0)], sessions: [])
        XCTAssertEqual(result["e1"]?.isFinished, true)
    }

    func testAnItemNeverStartedIsNotFinished() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")], items: [item("i1", reference: "https://example.com/e1")], sessions: [])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "i1", isFinished: false))
    }

    func testAPodcastMatchesByItsAudioAddressEvenWhenItsPageAddressDiffers() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1", page: "https://example.com/show/ep-1", audio: "https://cdn.example.com/ep1.mp3")],
            items: [item("i1", reference: "https://elsewhere.example/other", media: "https://cdn.example.com/ep1.mp3")],
            sessions: [])
        XCTAssertEqual(result["e1"]?.itemID, "i1")
    }

    func testNeighbouringAddressesStillMatch() {
        // Host case, a trailing slash and stray spaces are the same address for matching, as for the follow check.
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1", page: "https://Example.com/Posts/One/")],
            items: [item("i1", reference: " https://example.com/Posts/One ")], sessions: [])
        XCTAssertEqual(result["e1"]?.itemID, "i1")
        // A different path is a different episode.
        let other = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1", page: "https://example.com/posts/one")],
            items: [item("i1", reference: "https://example.com/posts/two")], sessions: [])
        XCTAssertTrue(other.isEmpty)
    }

    func testAPageSeveralEntriesShareMatchesNoneUnlessTheImportRecordNamesOne() {
        let shared = "https://example.com/roundup"
        let entries = [entry("e1", page: shared), entry("e2", page: shared)]
        let items = [item("i1", reference: shared)]
        XCTAssertTrue(FollowingLibraryEpisodes.resolve(entries: entries, items: items, sessions: []).isEmpty)
        let named = FollowingLibraryEpisodes.resolve(
            entries: entries, items: items, sessions: [],
            importedEntryIds: [ListeningSignalImportedEntries.itemKey("i1"): "e2"])
        XCTAssertEqual(named["e2"]?.itemID, "i1")
        XCTAssertNil(named["e1"])
    }

    func testAnItemInRecentlyDeletedNoLongerCountsAsSaved() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")], items: [item("i1", reference: "https://example.com/e1", deletedAt: t0)], sessions: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testOnlyImportedEntriesMatch() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1", state: .unseen), entry("e2", state: .dismissed)],
            items: [item("i1", reference: "https://example.com/e1"), item("i2", reference: "https://example.com/e2")], sessions: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testAFinishedOlderCopyBesideAnUnstartedNewerOneCountsAsHeard() {
        // #3691: the later copy still names the item, but the episode was heard, so the row shows no ▶ on it.
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")],
            items: [
                item("old", reference: "https://example.com/e1", completedAt: t0, createdAt: t0),
                item("new", reference: "https://example.com/e1", createdAt: t0.addingTimeInterval(60)),
            ],
            sessions: [])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "new", isFinished: true))
    }

    func testAnOlderCopyHeardInASessionBesideAnUnstartedNewerOneCountsAsHeard() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")],
            items: [
                item("old", reference: "https://example.com/e1", createdAt: t0),
                item("new", reference: "https://example.com/e1", createdAt: t0.addingTimeInterval(60)),
            ],
            sessions: [session("old", percent: 100, status: "finished", phase: .finished)])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "new", isFinished: true))
    }

    func testTwoUnfinishedCopiesAreNotHeardAndTheLaterOneNamesTheItem() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")],
            items: [
                item("old", reference: "https://example.com/e1", createdAt: t0),
                item("new", reference: "https://example.com/e1", createdAt: t0.addingTimeInterval(60)),
            ],
            sessions: [session("old", percent: 40), session("new", percent: 10)])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "new", isFinished: false))
    }

    // MARK: The heard rule (#3691): 95%, or the last two minutes, whichever comes first.

    private func podcast(_ id: String, durationMs: Int?) -> LibraryItemSummary {
        LibraryItemSummary(
            id: id, title: id, mediaType: "podcast", status: "ready", externalReference: "https://example.com/\(id)",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/\(id).mp3", durationMs: durationMs),
            hasListenableText: false, textCharacterCount: nil)
    }

    private func mediaSession(_ itemId: String, percent: Int, positionMs: Int?) -> Session {
        var made = session(itemId, percent: percent)
        made.position = Position(mediaTimeMs: positionMs)
        return made
    }

    private func isFinished(_ item: LibraryItemSummary, _ sessions: [Session], entryDurationMs: Int? = nil) -> Bool? {
        var entry = entry("e1", page: item.externalReference)
        entry.audioDurationMs = entryDurationMs
        return FollowingLibraryEpisodes.resolve(entries: [entry], items: [item], sessions: sessions)["e1"]?.isFinished
    }

    func testAnEpisodeAt96PercentIsHeardAndOneAt94IsNot() {
        let ep = podcast("ep", durationMs: 3_600_000)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 96, positionMs: 3_456_000)]), true)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 95, positionMs: 3_420_000)]), true)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 94, positionMs: 3_384_000)]), false)
    }

    func testAnEpisodeNinetySecondsFromTheEndIsHeardEvenBelow95Percent() {
        // 20 minutes: 90 seconds left is 92.5%, short of 95 but inside the last two minutes.
        let ep = podcast("ep", durationMs: 1_200_000)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 92, positionMs: 1_110_000)]), true)
        // 3 minutes 10 seconds left is not.
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 84, positionMs: 1_010_000)]), false)
    }

    func testTheLastTwoMinutesAreReadFromTheFeedsDurationWhenTheItemHasNone() {
        let ep = podcast("ep", durationMs: nil)
        let late = [mediaSession("ep", percent: 91, positionMs: 1_100_000)]
        XCTAssertEqual(isFinished(ep, late, entryDurationMs: 1_200_000), true)
        XCTAssertEqual(isFinished(ep, late, entryDurationMs: nil), false, "no duration anywhere: only the percent can say")
    }

    func testAFeedDurationShorterThanTheRealAudioDoesNotMakeAnUnheardEpisodeHeard() {
        // The feed says 30 minutes but the real audio runs longer (inserted ads). Near the feed's end the player's
        // own percent is still low, so the last-two-minutes rule must not fire; nor past the feed's end.
        let ep = podcast("ep", durationMs: 1_800_000)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 40, positionMs: 1_740_000)]), false)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 40, positionMs: 1_900_000)]), false, "past the feed's end")
    }

    func testAnItemDurationOfZeroFallsBackToTheFeedsDuration() {
        let ep = podcast("ep", durationMs: 0)
        XCTAssertEqual(isFinished(ep, [mediaSession("ep", percent: 92, positionMs: 1_110_000)], entryDurationMs: 1_200_000), true)
    }

    func testTheNewerCopyHeardBesideAnUnstartedOlderOneCountsAsHeard() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")],
            items: [
                item("old", reference: "https://example.com/e1", createdAt: t0),
                item("new", reference: "https://example.com/e1", completedAt: t0, createdAt: t0.addingTimeInterval(60)),
            ],
            sessions: [])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "new", isFinished: true))
    }

    func testAShortClipIsNotHeardAtItsFirstMinute() {
        // A 3-minute clip is within two minutes of its end after the first minute; the half-way guard stops that.
        let clip = podcast("clip", durationMs: 180_000)
        XCTAssertEqual(isFinished(clip, [mediaSession("clip", percent: 33, positionMs: 60_000)]), false)
        XCTAssertEqual(isFinished(clip, [mediaSession("clip", percent: 60, positionMs: 108_000)]), true)
    }

    func testAnArticleHasNoMediaTimeSoOnlyThePercentCounts() {
        XCTAssertEqual(isFinished(item("a", reference: "https://example.com/a"), [session("a", percent: 96)]), true)
        XCTAssertEqual(isFinished(item("a", reference: "https://example.com/a"), [session("a", percent: 80)]), false)
    }

    func testAnItemOfNoFollowedEpisodeIsIgnoredAndNoEntriesIsEmpty() {
        XCTAssertTrue(FollowingLibraryEpisodes.resolve(entries: [], items: [item("i1", reference: "https://example.com/x")], sessions: []).isEmpty)
        XCTAssertTrue(FollowingLibraryEpisodes.resolve(entries: [entry("e1")], items: [item("i1", reference: "https://example.com/x")], sessions: []).isEmpty)
    }
}
