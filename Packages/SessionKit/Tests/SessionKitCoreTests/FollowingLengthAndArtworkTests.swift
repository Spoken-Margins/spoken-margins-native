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

    private func parse(_ text: String) throws -> ParsedFeed {
        try FeedParser().parse(data: Data(text.utf8))
    }
}
