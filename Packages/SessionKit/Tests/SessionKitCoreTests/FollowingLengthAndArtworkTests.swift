import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// Following rows' length and artwork (#773): `ListenLength`, the feed's channel image, and the
/// artwork side file.
final class FollowingLengthAndArtworkTests: XCTestCase {
    // MARK: ListenLength

    func testAPodcastShowsItsDuration() {
        let length = ListenLength(audioDurationMs: 42 * 60_000 + 20_000, bodyWordCount: 9_000)
        XCTAssertEqual(length?.label, "42 min", "the episode's duration wins over any show notes")
        XCTAssertEqual(length?.spokenLabel, "42 minutes")
        XCTAssertEqual(ListenLength(audioDurationMs: 65 * 60_000, bodyWordCount: nil)?.label, "1 h 5 min")
        XCTAssertEqual(ListenLength(audioDurationMs: 65 * 60_000, bodyWordCount: nil)?.spokenLabel, "1 hour 5 minutes")
        XCTAssertEqual(ListenLength(audioDurationMs: 120 * 60_000, bodyWordCount: nil)?.label, "2 h")
    }

    func testAnArticleIsEstimatedFromItsWordsAtTheSpeechRate() {
        XCTAssertEqual(ListenLength(audioDurationMs: nil, bodyWordCount: 2_160)?.label, "12 min listen")
        XCTAssertEqual(ListenLength(audioDurationMs: nil, bodyWordCount: 2_160, rate: 1.5)?.label, "8 min listen")
        XCTAssertEqual(ListenLength(audioDurationMs: nil, bodyWordCount: 2_160, rate: 0)?.label, "12 min listen", "a bad rate counts as 1x")
        XCTAssertEqual(ListenLength(audioDurationMs: nil, bodyWordCount: 40)?.label, "1 min listen")
    }

    func testAnEntryWithNeitherHasNoLength() {
        XCTAssertNil(ListenLength(audioDurationMs: nil, bodyWordCount: nil))
        XCTAssertNil(ListenLength(audioDurationMs: 0, bodyWordCount: 0))
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/e", title: "E")
        XCTAssertNil(ListenLength(entry))
    }

    func testAnEpisodeWithoutADurationIsNotTimedFromItsShowNotes() {
        let episode = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/e", audioURL: "https://example.com/e.mp3", title: "E", bodyWordCount: 400)
        XCTAssertNil(ListenLength(episode), "show notes are not the episode, so an hour-long show must not read \"2 min listen\"")
        let timed = FeedEntry(id: "t", subscriptionId: "s", canonicalURL: "https://example.com/t", audioURL: "https://example.com/t.mp3", title: "T", bodyWordCount: 400, audioDurationMs: 42 * 60_000)
        XCTAssertEqual(ListenLength(timed)?.label, "42 min")
    }

    // MARK: Channel image

    func testRSSPrefersTheItunesImageThenTheChannelImage() throws {
        let both = try parse("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title>
        <image><url>https://example.com/small.png</url><title>Show</title><link>https://example.com</link></image>
        <itunes:image href="https://example.com/square.jpg"/>
        <item><title>A</title><link>https://example.com/a</link><itunes:image href="https://example.com/episode-a.jpg"/></item>
        </channel></rss>
        """)
        XCTAssertEqual(both.imageURL, "https://example.com/square.jpg")
        XCTAssertEqual(both.title, "Show")
        XCTAssertEqual(both.items.map(\.title), ["A"])

        let channelOnly = try parse("""
        <rss version="2.0"><channel><title>Show</title>
        <image><url>https://example.com/small.png</url></image>
        <item><title>A</title><link>https://example.com/a</link></item></channel></rss>
        """)
        XCTAssertEqual(channelOnly.imageURL, "https://example.com/small.png")
    }

    func testAnEpisodeImageIsNotTheShowImage() throws {
        let parsed = try parse("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title>
        <item><title>A</title><link>https://example.com/a</link><itunes:image href="https://example.com/episode-a.jpg"/></item>
        </channel></rss>
        """)
        XCTAssertNil(parsed.imageURL)
    }

    func testAtomUsesTheLogoThenTheIcon() throws {
        let logo = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title><icon>https://example.com/icon.png</icon>
        <logo>https://example.com/logo.png</logo>
        <entry><title>A</title><id>a</id><link href="https://example.com/a"/></entry></feed>
        """)
        XCTAssertEqual(logo.imageURL, "https://example.com/logo.png")
        let icon = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title><icon>https://example.com/icon.png</icon>
        <entry><title>A</title><id>a</id><link href="https://example.com/a"/></entry></feed>
        """)
        XCTAssertEqual(icon.imageURL, "https://example.com/icon.png")
    }

    func testOnlyAnHttpsImageIsKept() throws {
        let parsed = try parse("""
        <rss version="2.0"><channel><title>Show</title><image><url>http://example.com/plain.png</url></image></channel></rss>
        """)
        XCTAssertNil(parsed.imageURL)
        let json = try parse(#"{"version":"https://jsonfeed.org/version/1.1","title":"J","icon":"https://example.com/j.png","items":[]}"#)
        XCTAssertEqual(json.imageURL, "https://example.com/j.png")
    }

    // MARK: Artwork side file

    func testTheCachePrefersCatalogArtworkSurvivesRelaunchAndDropsUnfollowedShows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(FollowingArtworkCache.fileName)

        var cache = FollowingArtworkCache.load(from: file)
        XCTAssertNil(cache.artworkURL(for: "sub-a"), "no file yet")
        cache.record(feedURL: "https://feed.example/a.jpg", for: "sub-a")
        XCTAssertEqual(cache.artworkURL(for: "sub-a")?.absoluteString, "https://feed.example/a.jpg")
        cache.record(catalogURL: "https://catalog.example/a.jpg", for: "sub-a")
        cache.record(feedURL: "https://feed.example/b.jpg", for: "sub-b")
        cache.record(feedURL: nil, for: "sub-b")
        cache.record(feedURL: "http://insecure.example/c.jpg", for: "sub-c")
        try cache.save(to: file)

        var reloaded = FollowingArtworkCache.load(from: file)
        XCTAssertEqual(reloaded, cache)
        XCTAssertEqual(reloaded.artworkURL(for: "sub-a")?.absoluteString, "https://catalog.example/a.jpg", "catalog wins")
        XCTAssertEqual(reloaded.artworkURL(for: "sub-b")?.absoluteString, "https://feed.example/b.jpg", "a refresh without an image keeps it")
        XCTAssertNil(reloaded.artworkURL(for: "sub-c"))

        reloaded.remove(subscriptionID: "sub-a")
        XCTAssertNil(reloaded.artworkURL(for: "sub-a"))
        reloaded.keepOnly([])
        XCTAssertEqual(reloaded.bySubscription, [:])
    }

    func testAnUnreadableFileMeansNoArtwork() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(FollowingArtworkCache.fileName)
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(FollowingArtworkCache.load(from: file), FollowingArtworkCache())
    }

    // MARK: Row

    func testAnEpisodeRowShowsItsArtworkLengthAndReadsShowTitleLength() {
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/e", audioURL: "https://example.com/e.mp3",
                              title: "Housing costs", audioDurationMs: 42 * 60_000)
        let art = URL(string: "https://example.com/show.jpg")
        let row = FollowingEntryRow(entry: entry, showTitle: "The Daily", artworkURL: art, rate: 2)
        XCTAssertEqual(row.artworkURL, art)
        XCTAssertEqual(row.length?.label, "42 min", "an episode's length is its duration, not scaled by the speech rate")
        XCTAssertEqual(row.accessibilityLabel, "The Daily. Housing costs. 42 minutes.")
    }

    func testAnArticleRowIsTimedAtTheSpeechRateAndFallsBackToAPageIcon() {
        let entry = FeedEntry(id: "a", subscriptionId: "s", canonicalURL: "https://example.com/a", title: "On cities.", bodyWordCount: 2_160)
        let row = FollowingEntryRow(entry: entry, showTitle: "Lab Notes", artworkURL: nil, rate: 1.5)
        XCTAssertNil(row.artworkURL)
        XCTAssertEqual(row.placeholder, .page)
        XCTAssertEqual(row.length?.label, "8 min listen")
        XCTAssertEqual(row.accessibilityLabel, "Lab Notes. On cities. 8 minutes.", "a title's own full stop isn't doubled")
    }

    func testAPodcastWithoutArtworkShowsTheShowsFirstLetter() {
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/e", audioURL: "https://example.com/e.mp3", title: "Episode 12")
        XCTAssertEqual(FollowingEntryRow(entry: entry, showTitle: "the daily", artworkURL: nil).placeholder, .initial("T"))
        XCTAssertEqual(FollowingEntryRow(entry: entry, showTitle: "99% Invisible", artworkURL: nil).placeholder, .initial("9"))
        XCTAssertEqual(FollowingEntryRow(entry: entry, showTitle: "  ", artworkURL: nil).placeholder, .initial("E"), "no show name: the entry's title")
    }

    func testAnEntryWithNoLengthOrShowReadsOnlyItsTitle() {
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/e", audioURL: "https://example.com/e.mp3", title: "Episode 12")
        let row = FollowingEntryRow(entry: entry, showTitle: nil, artworkURL: nil)
        XCTAssertNil(row.length, "no \"0 min\" placeholder")
        XCTAssertEqual(row.accessibilityLabel, "Episode 12.")
    }

    func testCatalogArtworkIsRecordedForFollowedShowsTheCatalogLists() {
        let catalog = SourceCatalog(
            schemaVersion: SourceCatalog.currentSchemaVersion, catalogId: "test", contentVersion: 1, title: "Test",
            generatedAt: "2026-10-04T00:00:00Z", locale: "en-US", provenance: [], subjects: [], starterRows: nil,
            entries: [
                SourceCatalogEntry(id: "daily", kind: .podcastFeed, contentKind: .podcast, title: "The Daily",
                                   feedURL: "https://feeds.example.com/daily.xml", artworkURL: "https://catalog.example/daily.jpg",
                                   subjects: [], provenanceIds: []),
                SourceCatalogEntry(id: "plain", kind: .podcastFeed, contentKind: .podcast, title: "No art",
                                   feedURL: "https://feeds.example.com/plain.xml", subjects: [], provenanceIds: []),
            ]
        )
        func subscription(_ id: String, _ url: String) -> FeedSubscription {
            FeedSubscription(id: id, source: SourceIdentity(id: id, kind: .podcastFeed, canonicalURL: url, host: "feeds.example.com"))
        }
        var cache = FollowingArtworkCache()
        cache.record(feedURL: "https://feed.example/daily-own.jpg", for: "sub-daily")
        let followed = [
            subscription("sub-daily", "http://FEEDS.example.com/daily.xml/"),
            subscription("sub-plain", "https://feeds.example.com/plain.xml"),
            subscription("sub-other", "https://elsewhere.example/feed"),
        ]
        XCTAssertTrue(cache.recordCatalogArtwork(for: followed, catalog: catalog))
        XCTAssertEqual(cache.artworkURL(for: "sub-daily")?.absoluteString, "https://catalog.example/daily.jpg", "catalog wins over the feed's image")
        XCTAssertNil(cache.artworkURL(for: "sub-plain"))
        XCTAssertNil(cache.artworkURL(for: "sub-other"))
        XCTAssertFalse(cache.recordCatalogArtwork(for: followed, catalog: catalog), "nothing new, so no save")
        XCTAssertFalse(cache.recordCatalogArtwork(for: followed, catalog: nil), "no catalog loaded yet")
    }

    func testTheStoreWritesChangesStraightAwayAndDropsShowsNoLongerFollowed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(FollowingArtworkCache.fileName)
        func subscription(_ id: String) -> FeedSubscription {
            FeedSubscription(id: id, source: SourceIdentity(id: id, kind: .podcastFeed, canonicalURL: "https://feeds.example.com/\(id).xml", host: "feeds.example.com"))
        }

        var store = FollowingArtworkStore(file: file)
        store.reconcile(with: [], catalog: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing changed, nothing written")
        store.recordFeedArtwork("https://feed.example/a.jpg", for: "a")
        store.recordFeedArtwork("https://feed.example/b.jpg", for: "b")
        store.recordFeedArtwork("https://feed.example/c.jpg", for: "c")
        XCTAssertEqual(FollowingArtworkStore(file: file).cache, store.cache, "a relaunch reads what was recorded")

        store.remove(subscriptionID: "a")
        store.reconcile(with: [subscription("b")], catalog: nil)  // "c" was unfollowed elsewhere
        let relaunched = FollowingArtworkStore(file: file)
        XCTAssertNil(relaunched.cache.artworkURL(for: "a"))
        XCTAssertNil(relaunched.cache.artworkURL(for: "c"))
        XCTAssertEqual(relaunched.cache.artworkURL(for: "b")?.absoluteString, "https://feed.example/b.jpg")

        var inMemory = FollowingArtworkStore(file: nil)
        inMemory.recordFeedArtwork("https://feed.example/a.jpg", for: "a")
        XCTAssertNotNil(inMemory.cache.artworkURL(for: "a"))
    }

    private func parse(_ text: String) throws -> ParsedFeed {
        try FeedParser().parse(data: Data(text.utf8))
    }
}
