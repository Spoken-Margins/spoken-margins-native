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

    func testAReImportedEpisodeIsJudgedByItsLaterCopy() {
        let result = FollowingLibraryEpisodes.resolve(
            entries: [entry("e1")],
            items: [
                item("old", reference: "https://example.com/e1", completedAt: t0, createdAt: t0),
                item("new", reference: "https://example.com/e1", createdAt: t0.addingTimeInterval(60)),
            ],
            sessions: [])
        XCTAssertEqual(result["e1"], FollowingLibraryEpisode(itemID: "new", isFinished: false))
    }

    func testAnItemOfNoFollowedEpisodeIsIgnoredAndNoEntriesIsEmpty() {
        XCTAssertTrue(FollowingLibraryEpisodes.resolve(entries: [], items: [item("i1", reference: "https://example.com/x")], sessions: []).isEmpty)
        XCTAssertTrue(FollowingLibraryEpisodes.resolve(entries: [entry("e1")], items: [item("i1", reference: "https://example.com/x")], sessions: []).isEmpty)
    }
}
