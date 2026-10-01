import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
@testable import SessionKitPersistence

/// #545: a followed post with both its full text and the publisher's own recording (a Substack
/// voiceover) became a podcast episode with no text, because the parser folded the post's body
/// into the short description and every entry with audio imported as audio.
final class PublisherAudioDetectorTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: Parser

    func testParserKeepsTheFullBodyApartFromTheDescription() throws {
        let items = try Self.substackItems()
        let voiceover = try XCTUnwrap(items.first { $0.title == "The harbor in winter" })
        XCTAssertNotNil(voiceover.audioURL)
        XCTAssertEqual(voiceover.durationMs, 1_312_000)
        let body = try XCTUnwrap(voiceover.content)
        XCTAssertFalse(body.contains("<p>"), "tags are stripped")
        XCTAssertFalse(body.contains("A short subtitle"), "the description isn't mixed in")
        XCTAssertGreaterThanOrEqual(PublisherAudioDetector.bodyWordCount(of: voiceover) ?? 0, 700)
        XCTAssertEqual(voiceover.summary, body, "summary still takes the last of description and body, as before")
    }

    func testFeedsWithoutABodyGiveNone() throws {
        let rss = Data("""
        <rss version="2.0"><channel><title>T</title>
        <item><title>A</title><link>https://example.com/a</link><description>Short notes.</description>
        <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/><media:content url="https://example.com/a.jpg"/></item>
        </channel></rss>
        """.utf8)
        let item = try XCTUnwrap(try FeedParser().parse(data: rss).items.first)
        XCTAssertNil(item.content)
        XCTAssertNil(PublisherAudioDetector.bodyWordCount(of: item))

        let json = Data("""
        {"version": "https://jsonfeed.org/version/1.1", "title": "T", "items": [
          {"id": "1", "url": "https://example.com/1", "summary": "Short.", "content_html": "<p>Full body here.</p>"}
        ]}
        """.utf8)
        XCTAssertEqual(try FeedParser().parse(data: json).items.first?.content, "Full body here.")
    }

    // MARK: Detector

    func testASubstackVoiceoverPostIsAnArticleWithPublisherAudio() throws {
        let voiceover = try XCTUnwrap(try Self.substackItems().first { $0.title == "The harbor in winter" })
        XCTAssertEqual(PublisherAudioDetector.kind(of: voiceover), .articleWithPublisherAudio)
    }

    func testAnEpisodeWithShortShowNotesIsStillAPodcastEpisode() throws {
        let episode = try XCTUnwrap(try Self.substackItems().first { $0.title == "Episode 12: A harbor pilot" })
        XCTAssertNotNil(episode.content)
        XCTAssertEqual(PublisherAudioDetector.kind(of: episode), .podcastEpisode)
        for item in try FeedParser().parse(data: Self.fixture("enclosure-only-episodes.rss")).items {
            XCTAssertEqual(PublisherAudioDetector.kind(of: item), .podcastEpisode, item.title)
        }
    }

    func testATextOnlyPostIsAnArticleWithoutAudio() throws {
        let post = try XCTUnwrap(try Self.substackItems().first { $0.title == "Notes from the archive" })
        XCTAssertNil(post.audioURL)
        XCTAssertEqual(PublisherAudioDetector.kind(of: post), .article)
    }

    func testLongNotesOnAnEpisodeWhoseLinkIsItsAudioStayAPodcastEpisode() {
        let audio = "https://media.example.com/show/ep1.mp3"
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: audio, pageURL: audio, bodyWordCount: 5_000), .podcastEpisode)
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: audio, pageURL: "https://example.com/p/1", bodyWordCount: 599), .podcastEpisode)
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: audio, pageURL: "https://example.com/p/1", bodyWordCount: 600), .articleWithPublisherAudio)
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: "http://media.example.com/a.mp3", pageURL: "https://example.com/p/1", bodyWordCount: 900), .article,
                       "a non-https enclosure isn't audio the app would play")
    }

    func testEntriesSavedBeforeBodiesWereCountedImportAsBefore() {
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/p/1", audioURL: "https://example.com/1.mp3", title: "Old")
        XCTAssertNil(entry.bodyWordCount)
        XCTAssertFalse(entry.hasPublisherAudio)
        XCTAssertNil(PublisherAudioDetector.publisherAudio(for: entry, itemId: "item"))
    }

    func testThePublisherAudioRecordComesFromTheEntry() throws {
        let entry = FeedEntry(
            id: "e", subscriptionId: "s", canonicalURL: "https://marginsweekly.substack.com/p/the-harbor-in-winter",
            audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", title: "The harbor in winter",
            bodyWordCount: 720, audioDurationMs: 1_312_000
        )
        XCTAssertTrue(entry.hasPublisherAudio)
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: entry, itemId: "item-1"), PublisherAudio(
            itemId: "item-1", audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", durationMs: 1_312_000, detectedFrom: "feed_enclosure"
        ))
    }

    func testWordCountIgnoresPunctuationOnlyTokens() {
        XCTAssertEqual(PublisherAudioDetector.wordCount("One, two — three.\n\n4 five"), 5)
        XCTAssertEqual(PublisherAudioDetector.wordCount("  "), 0)
    }

    // MARK: Feed entries and the record kind

    func testFeedEntriesKeepTheNewFieldsAndOldPayloadsStillDecode() throws {
        let store = try SQLiteSessionStore(path: temporary.appendingPathComponent("entries.sqlite").path)
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/p/1", audioURL: "https://example.com/1.mp3",
                              title: "Post", bodyWordCount: 720, audioDurationMs: 60_000)
        try store.saveFeedEntry(entry)
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: "s"), [entry])

        let old = Data(#"{"id":"e","subscriptionId":"s","canonicalURL":"https://example.com/p/1","title":"Post","state":"unseen"}"#.utf8)
        let decoded = try JSONDecoder().decode(FeedEntry.self, from: old)
        XCTAssertNil(decoded.bodyWordCount)
        XCTAssertNil(decoded.audioDurationMs)
    }

    func testPublisherAudioRoundTripsBesideAnUnchangedArticleAndGoesWithTheItem() throws {
        let store = try SQLiteSessionStore(path: temporary.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "article", displayName: "Article", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://marginsweekly.substack.com/p/the-harbor-in-winter", title: "The harbor in winter"),
            text: "The harbor in winter. It was cold."
        ))
        let before = try store.loadItem(id: item.id)
        XCTAssertNil(try store.loadPublisherAudio(itemId: item.id))

        let audio = PublisherAudio(itemId: item.id, audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", durationMs: 1_312_000, detectedFrom: "feed_enclosure")
        try store.savePublisherAudio(audio)
        XCTAssertEqual(try store.loadPublisherAudio(itemId: item.id), audio)
        XCTAssertEqual(try store.loadItem(id: item.id), before, "the item itself is a plain article, as Build 29 sees it")
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: temporary.appendingPathComponent("library.sqlite").path), 5)

        let reopened = try SQLiteSessionStore(path: temporary.appendingPathComponent("library.sqlite").path)
        XCTAssertEqual(try reopened.loadPublisherAudio(itemId: item.id), audio)
        try reopened.deleteItem(id: item.id)
        XCTAssertNil(try reopened.loadPublisherAudio(itemId: item.id))

        let memory = InMemorySessionRepository()
        try memory.savePublisherAudio(audio)
        XCTAssertEqual(try memory.loadPublisherAudio(itemId: item.id), audio)
    }

    // MARK: Fixtures

    private static func substackItems() throws -> [ParsedFeedItem] {
        try FeedParser().parse(data: fixture("substack-publisher-audio.rss")).items
    }

    private static func fixture(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        return try Data(contentsOf: root.appendingPathComponent("Contracts/fixtures/feeds/\(name)"))
    }
}
