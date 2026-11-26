import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The length a stored episode gets before its first play (#4186): from a followed show's stored feed entry, and from
/// the downloaded file, both only when the item has none.
final class EpisodeLengthBackfillTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-episode-length-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openStore() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: directory.appending(path: "store-\(UUID().uuidString).sqlite").path)
    }

    private func episode(
        _ id: String, audio: String?, duration: Int? = nil, source: AudioSourceType = .remoteStream, deleted: Bool = false
    ) -> Item {
        Item(
            id: id, title: "Episode \(id)", mediaType: "transcript_backed_media", text: nil, externalReference: audio,
            status: "ready", externalReferenceType: "url", media: ItemMedia(sourceType: source, url: audio, durationMs: duration),
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_000) : nil)
    }

    private func article(_ id: String) -> Item {
        Item(id: id, title: "Article \(id)", mediaType: "text", text: "Some words to read aloud.", externalReference: nil, status: "ready")
    }

    private func entry(_ id: String, audio: String?, duration: Int?) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: "sub", canonicalURL: "https://show.example/\(id)", audioURL: audio,
            title: "Episode \(id)", audioDurationMs: duration, episodeGUID: "guid-\(id)")
    }

    private func fills(_ items: [Item], _ entries: [FeedEntry], excluding: String? = nil) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: EpisodeLengthBackfill.statedFills(items: items, entries: entries, excludingItemId: excluding)
            .map { ($0.itemId, $0.durationMs) })
    }

    // MARK: statedFills

    func testUrlMatchFillsTheLengthTheEntryStates() {
        let result = fills([episode("a", audio: "https://cdn.example/a.mp3")], [entry("e", audio: "https://cdn.example/a.mp3", duration: 3_725_000)])
        XCTAssertEqual(result, ["a": 3_725_000])
    }

    func testUrlThatDiffersOnlyByAQueryStringIsNotAMatch() {
        let result = fills([episode("a", audio: "https://cdn.example/a.mp3?ref=feed")], [entry("e", audio: "https://cdn.example/a.mp3", duration: 60_000)])
        XCTAssertTrue(result.isEmpty, "the comparison is exact, as in RecoveredEpisodeLookup")
    }

    func testEntryWithoutALengthFillsNothing() {
        let items = [episode("a", audio: "https://cdn.example/a.mp3")]
        XCTAssertTrue(fills(items, [entry("e", audio: "https://cdn.example/a.mp3", duration: nil)]).isEmpty)
        XCTAssertTrue(fills(items, [entry("e", audio: "https://cdn.example/a.mp3", duration: 0)]).isEmpty)
        XCTAssertTrue(fills(items, [entry("e", audio: "https://cdn.example/a.mp3", duration: -5)]).isEmpty)
        XCTAssertTrue(fills(items, [entry("e", audio: nil, duration: 60_000)]).isEmpty)
    }

    func testAnItemThatHasALengthIsSkipped() {
        let items = [episode("a", audio: "https://cdn.example/a.mp3", duration: 1_800_000)]
        XCTAssertTrue(fills(items, [entry("e", audio: "https://cdn.example/a.mp3", duration: 3_725_000)]).isEmpty)
    }

    func testAStoredZeroCountsAsMissing() {
        let result = fills([episode("a", audio: "https://cdn.example/a.mp3", duration: 0)], [entry("e", audio: "https://cdn.example/a.mp3", duration: 90_000)])
        XCTAssertEqual(result, ["a": 90_000])
    }

    func testTextAndNarrationItemsAreSkipped() {
        var narrated = article("n")
        narrated.media = ItemMedia(sourceType: .generatedTTSPrerendered, url: "https://cdn.example/a.mp3")
        let result = fills([article("t"), narrated], [entry("e", audio: "https://cdn.example/a.mp3", duration: 60_000)])
        XCTAssertTrue(result.isEmpty)
    }

    func testTheCurrentItemAndDeletedItemsAreLeftOut() {
        let items = [
            episode("current", audio: "https://cdn.example/a.mp3"),
            episode("gone", audio: "https://cdn.example/a.mp3", deleted: true),
            episode("other", audio: "https://cdn.example/a.mp3"),
        ]
        let result = fills(items, [entry("e", audio: "https://cdn.example/a.mp3", duration: 60_000)], excluding: "current")
        XCTAssertEqual(result, ["other": 60_000])
    }

    func testTheFirstEntryWithALengthWins() {
        let result = fills(
            [episode("a", audio: "https://cdn.example/a.mp3")],
            [entry("e1", audio: "https://cdn.example/a.mp3", duration: nil),
             entry("e2", audio: "https://cdn.example/a.mp3", duration: 61_000),
             entry("e3", audio: "https://cdn.example/a.mp3", duration: 99_000)])
        XCTAssertEqual(result, ["a": 61_000])
    }

    func testEmptyInputs() {
        XCTAssertTrue(fills([], []).isEmpty)
        XCTAssertTrue(fills([episode("a", audio: "https://cdn.example/a.mp3")], []).isEmpty)
        XCTAssertTrue(fills([], [entry("e", audio: "https://cdn.example/a.mp3", duration: 60_000)]).isEmpty)
    }

    func testSummariesReadFromARealStoreMatchLikeItems() throws {
        let store = try openStore()
        try store.saveItem(episode("a", audio: "https://cdn.example/a.mp3"))
        try store.saveItem(episode("b", audio: "https://cdn.example/b.mp3", duration: 120_000))
        try store.saveItem(article("t"))
        let summaries: [any LibraryItemFields] = try store.listItemSummaries()
        let result = EpisodeLengthBackfill.statedFills(
            items: summaries,
            entries: [entry("ea", audio: "https://cdn.example/a.mp3", duration: 60_000), entry("eb", audio: "https://cdn.example/b.mp3", duration: 70_000)],
            excludingItemId: nil)
        XCTAssertEqual(result.map(\.itemId), ["a"])
        XCTAssertEqual(result.map(\.durationMs), [60_000])
    }

    /// A large Library and a large feed table: the match is a dictionary lookup, not a scan per item.
    func testTwoThousandItemsAgainstFiveThousandEntriesIsFast() {
        let items = (0..<2_000).map { episode("i\($0)", audio: "https://cdn.example/\($0).mp3") }
        let entries = (0..<5_000).map { entry("e\($0)", audio: "https://cdn.example/\($0).mp3", duration: 60_000 + $0) }
        let started = Date()
        let result = EpisodeLengthBackfill.statedFills(items: items, entries: entries, excludingItemId: nil)
        XCTAssertEqual(result.count, 2_000)
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.007 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a scan of the 5,000 feed entries per item in place of a dictionary lookup.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    // MARK: fillMissingMediaDuration

    func testFillsAMissingLengthAndChangesNothingElse() throws {
        let store = try openStore()
        let before = episode("a", audio: "https://cdn.example/a.mp3")
        try store.saveItem(before)
        XCTAssertTrue(try store.fillMissingMediaDuration(itemId: "a", durationMs: 3_725_000))
        var expected = try store.loadItem(id: "a")
        XCTAssertEqual(expected.media?.durationMs, 3_725_000)
        expected.media?.durationMs = nil
        XCTAssertEqual(expected, before, "only media.durationMs changed")
    }

    func testFillsAStoredZero() throws {
        let store = try openStore()
        try store.saveItem(episode("a", audio: "https://cdn.example/a.mp3", duration: 0))
        XCTAssertTrue(try store.fillMissingMediaDuration(itemId: "a", durationMs: 90_000))
        XCTAssertEqual(try store.loadItem(id: "a").media?.durationMs, 90_000)
    }

    func testKeepsALengthThePlayerWroteFirst() throws {
        let store = try openStore()
        try store.saveItem(episode("a", audio: "https://cdn.example/a.mp3", duration: 1_800_000))
        XCTAssertFalse(try store.fillMissingMediaDuration(itemId: "a", durationMs: 3_725_000))
        XCTAssertEqual(try store.loadItem(id: "a").media?.durationMs, 1_800_000)
    }

    func testTheFirstFillWinsAndTheSecondDoesNothing() throws {
        let store = try openStore()
        try store.saveItem(episode("a", audio: "https://cdn.example/a.mp3"))
        XCTAssertTrue(try store.fillMissingMediaDuration(itemId: "a", durationMs: 60_000))
        XCTAssertFalse(try store.fillMissingMediaDuration(itemId: "a", durationMs: 61_000))
        XCTAssertEqual(try store.loadItem(id: "a").media?.durationMs, 60_000)
    }

    func testLeavesTextAndNarrationAlone() throws {
        let store = try openStore()
        var narrated = article("n")
        narrated.media = ItemMedia(sourceType: .generatedTTSPrerendered, url: nil)
        try store.saveItem(article("t"))
        try store.saveItem(narrated)
        XCTAssertFalse(try store.fillMissingMediaDuration(itemId: "t", durationMs: 60_000))
        XCTAssertFalse(try store.fillMissingMediaDuration(itemId: "n", durationMs: 60_000))
        XCTAssertNil(try store.loadItem(id: "t").media)
        XCTAssertNil(try store.loadItem(id: "n").media?.durationMs)
    }

    func testRefusesALengthThatIsNotPositive() throws {
        let store = try openStore()
        try store.saveItem(episode("a", audio: "https://cdn.example/a.mp3"))
        XCTAssertFalse(try store.fillMissingMediaDuration(itemId: "a", durationMs: 0))
        XCTAssertFalse(try store.fillMissingMediaDuration(itemId: "a", durationMs: -1))
        XCTAssertNil(try store.loadItem(id: "a").media?.durationMs)
    }

    /// The row and the item screen read the stored length through the same rule, after a new store opens the file.
    func testAFilledLengthSurvivesRelaunchAndBothScreensReadIt() throws {
        let path = directory.appending(path: "relaunch.sqlite").path
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveItem(episode("a", audio: "https://cdn.example/a.mp3"))
            XCTAssertTrue(try store.fillMissingMediaDuration(itemId: "a", durationMs: 3_725_000))
        }
        let reopened = try SQLiteSessionStore(path: path)
        let summary = try XCTUnwrap(try reopened.listItemSummaries().first)
        XCTAssertEqual(PlayableLength.ms(media: summary.media), 3_725_000)
        XCTAssertEqual(PlayableLength.ms(media: try reopened.loadItem(id: "a").media), 3_725_000)
    }

    func testAMissingItemThrowsInsteadOfFillingNothingQuietly() throws {
        let store = try openStore()
        XCTAssertThrowsError(try store.fillMissingMediaDuration(itemId: "nope", durationMs: 60_000))
    }

    /// A trash that lands between the fill's read and its save must not be undone by the fill's stale copy.
    func testAFillRacingATrashNeverBringsTheItemBack() throws {
        let store = try openStore()
        let ids = (0..<300).map { "race-\($0)" }
        for id in ids { try store.saveItem(episode(id, audio: "https://cdn.example/\(id).mp3")) }
        DispatchQueue.concurrentPerform(iterations: ids.count * 2) { index in
            let id = ids[index / 2]
            if index % 2 == 0 {
                _ = try? store.fillMissingMediaDuration(itemId: id, durationMs: 60_000)
            } else {
                try? store.moveItemToTrash(id: id)
            }
        }
        for id in ids {
            let item = try store.loadItem(id: id)
            XCTAssertNotNil(item.deletedAt, "\(id) was trashed, and the fill put it back")
            XCTAssertEqual(item.media?.durationMs, 60_000)
        }
    }
}
