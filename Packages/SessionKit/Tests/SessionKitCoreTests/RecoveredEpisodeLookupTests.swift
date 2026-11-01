import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// Finding the Library item that already is a recovered shared episode, and completing its identity, is one
/// background read that opens only the candidates and saves from the copy it read (#2506).
final class RecoveredEpisodeLookupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-recovered-episode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openStore(meter: StoreReadMeter? = nil) throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: directory.appending(path: "store-\(UUID().uuidString).sqlite").path, readMeter: meter)
    }

    private func entry(audio: String? = "https://cdn.example/ep12.mp3", guid: String? = "guid-12") -> FeedEntry {
        FeedEntry(
            id: "entry-12", subscriptionId: "sub", canonicalURL: "https://show.example/12", audioURL: audio,
            title: "Episode 12", summary: "About twelve.", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioDurationMs: 3_000_000, episodeGUID: guid)
    }

    private func podcast(_ id: String, title: String, audio: String?, guid: String? = nil, text: String? = nil) -> Item {
        var item = Item(
            id: id, title: title, mediaType: "transcript_backed_media", text: text, externalReference: audio, status: "ready",
            externalReferenceType: "url", media: ItemMedia(sourceType: .remoteStream, url: audio))
        item.episodeGUID = guid
        return item
    }

    /// The main-thread code this replaced, over the same store.
    private func oldLookup(_ store: SQLiteSessionStore, entry: FeedEntry, showTitle: String?, accepts: (Item) -> Bool) throws -> (String, Bool)? {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidateIDs = entry.recoveryCandidateItemIDs(among: try store.listItemSummaries())
        guard let id = try candidateIDs.lazy.compactMap({ try? store.loadItem(id: $0) }).first(where: { item in
            let same: Bool
            if let audio = entry.audioURL, item.media?.url == audio {
                same = true
            } else if let guid = entry.episodeGUID, item.episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines) == guid {
                same = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
            } else {
                same = false
            }
            return same && accepts(item)
        })?.id else { return nil }
        var item = try store.loadItem(id: id)
        let before = item
        entry.fillEpisodeIdentity(of: &item, showTitle: showTitle)
        if item.sourceTitle == nil { item.sourceTitle = item.showTitle }
        if item.media?.durationMs == nil, let feedDuration = entry.audioDurationMs { item.media?.durationMs = feedDuration }
        if item != before { try store.saveItem(item) }
        return (id, item != before)
    }

    private func seed(_ store: SQLiteSessionStore) throws {
        for item in [
            podcast("other", title: "Something else", audio: "https://cdn.example/other.mp3", text: String(repeating: "x", count: 50_000)),
            podcast("by-audio", title: "ep12", audio: "https://cdn.example/ep12.mp3"),
            podcast("same-title-no-audio", title: "  episode 12 ", audio: nil, guid: "guid-12"),
            podcast("same-title-other-guid", title: "Episode 12", audio: nil, guid: "guid-other")
        ] { try store.saveItem(item) }
    }

    func testTheOneReadFindsTheItemAndFillsItsIdentityAsTheMainThreadCodeDid() throws {
        for accepts: (Item) -> Bool in [{ _ in true }, { $0.id == "same-title-no-audio" }, { _ in false }] {
            let old = try openStore(), new = try openStore()
            try seed(old); try seed(new)
            let walked = try oldLookup(old, entry: entry(), showTitle: "The Show", accepts: accepts)
            let found = try new.findRecoveredEpisode(for: entry(), showTitle: "The Show", accepts: accepts)
            XCTAssertEqual(found?.itemId, walked?.0)
            XCTAssertEqual(found?.identityChanged, walked?.1)
            for id in ["other", "by-audio", "same-title-no-audio", "same-title-other-guid"] {
                XCTAssertEqual(try new.loadItem(id: id), try old.loadItem(id: id), "\(id) ends the same")
            }
        }
    }

    func testTheIdentityIsFilledAndASecondFindChangesNothing() throws {
        let store = try openStore()
        try seed(store)
        let first = try XCTUnwrap(store.findRecoveredEpisode(for: entry(), showTitle: "The Show") { $0.id == "by-audio" })
        XCTAssertEqual(first.itemId, "by-audio")
        XCTAssertTrue(first.identityChanged)
        let saved = try store.loadItem(id: "by-audio")
        XCTAssertEqual(saved.episodeGUID, "guid-12")
        XCTAssertEqual(saved.showTitle, "The Show")
        XCTAssertEqual(saved.sourceTitle, "The Show")
        XCTAssertEqual(saved.media?.durationMs, 3_000_000)
        XCTAssertFalse(try XCTUnwrap(store.findRecoveredEpisode(for: entry(), showTitle: "The Show") { $0.id == "by-audio" }).identityChanged)
        XCTAssertFalse(try store.completeEpisodeIdentity(itemId: "by-audio", entry: entry(), showTitle: "The Show"))
    }

    func testNoMatchSavesNothing() throws {
        let store = try openStore()
        try seed(store)
        XCTAssertNil(try store.findRecoveredEpisode(for: entry(audio: "https://cdn.example/none.mp3", guid: nil), showTitle: nil) { _ in true })
        XCTAssertNil(try store.findRecoveredEpisode(for: entry(), showTitle: nil) { _ in false })
    }

    /// Reads only the candidates (never the 50 KB item that cannot be this episode), and reads the found item once.
    func testItOpensOnlyTheCandidatesAndReadsTheFoundItemOnce() throws {
        let meter = StoreReadMeter()
        let old = try openStore(meter: meter), new = try openStore(meter: meter)
        try seed(old); try seed(new)

        meter.reset()
        _ = try oldLookup(old, entry: entry(), showTitle: "The Show") { $0.id == "by-audio" }
        let oldLoads = meter.totals(for: "loadItem(id:)")
        meter.reset()
        _ = try new.findRecoveredEpisode(for: entry(), showTitle: "The Show") { $0.id == "by-audio" }
        let newLoads = meter.totals(for: "loadItem(id:)")

        XCTAssertEqual(newLoads.calls, 1, "by-audio is the first candidate and is read once")
        XCTAssertEqual(oldLoads.calls, 2, "the old code read the found item again to save it")
        XCTAssertLessThan(newLoads.bytes, oldLoads.bytes)
        XCTAssertEqual(meter.totals(for: "listItems(includeDeleted:)").calls, 0, "never the whole-article list")
    }
}
