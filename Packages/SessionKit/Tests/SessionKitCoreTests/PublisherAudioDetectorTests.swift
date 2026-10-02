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
        XCTAssertNil(voiceover.audioURL, "the captured main feed uses image enclosures, not audio")
        XCTAssertNil(voiceover.durationMs)
        XCTAssertEqual(voiceover.publisherPlatform, "substack")
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
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: voiceover.url, title: voiceover.title,
                              bodyWordCount: PublisherAudioDetector.bodyWordCount(of: voiceover), fullBody: voiceover.content)
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(entry,
            html: String(decoding: Self.fixture("substack-voiceover-page.html"), as: UTF8.self)))
        XCTAssertEqual(PublisherAudioDetector.kind(of: confirmed), .articleWithPublisherAudio)
        XCTAssertEqual(confirmed.audioURL, "https://recordings.example/voiceover.mp3")
        XCTAssertEqual(PublisherAudioDetector.articleHandoff(for: confirmed)?.text, voiceover.content)
    }

    func testAnEpisodeWithShortShowNotesIsStillAPodcastEpisode() throws {
        let episode = try XCTUnwrap(try FeedParser().parse(data: Self.fixture("substack-transcript-podcast.rss")).items.first)
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
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: audio, pageURL: "https://example.com/p/1", bodyWordCount: 600), .podcastEpisode)
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: "http://media.example.com/a.mp3", pageURL: "https://example.com/p/1", bodyWordCount: 900), .article,
                       "a non-https enclosure isn't audio the app would play")
    }

    func testALongTranscriptWithAnEpisodePageStillImportsAsAPodcast() throws {
        let transcript = String(repeating: "The host and guest discuss the harbour today. ", count: 100)
        let xml = Data("""
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>A real podcast</title>
        <item><title>Episode with transcript</title><link>https://example.com/episodes/1</link>
        <enclosure url="https://example.com/audio/1.mp3" type="audio/mpeg"/>
        <content:encoded><![CDATA[<p>\(transcript)</p>]]></content:encoded></item>
        </channel></rss>
        """.utf8)
        let item = try XCTUnwrap(try FeedParser().parse(data: xml).items.first)
        XCTAssertGreaterThanOrEqual(PublisherAudioDetector.bodyWordCount(of: item) ?? 0, 600)
        XCTAssertEqual(PublisherAudioDetector.kind(of: item), .podcastEpisode)
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
            bodyWordCount: 720, publisherNarrationConfirmed: true, audioDurationMs: 1_312_000
        )
        XCTAssertTrue(entry.hasPublisherAudio)
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: entry, itemId: "item-1"), PublisherAudio(
            itemId: "item-1", audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", durationMs: 1_312_000, detectedFrom: "substack_post_voiceover"
        ))
    }

    func testOnlyTheCurrentPostsCompletedNarrationConfirmsPublisherAudio() throws {
        let html = String(decoding: try Self.fixture("substack-voiceover-page.html"), as: UTF8.self)
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://captured.example/p/voiceover",
                              title: "Article", bodyWordCount: 720)
        XCTAssertNotNil(PublisherNarrationEvidence.confirmedEntry(entry, html: html))
        for invalid in [
            html.replacingOccurrences(of: "newsletter", with: "podcast"),
            html.replacingOccurrences(of: "completed", with: "processing"),
            html.replacingOccurrences(of: "https://recordings.example", with: "http://recordings.example"),
            html.replacingOccurrences(of: "https://captured.example/p/voiceover", with: "https://captured.example/p/other"),
            html.replacingOccurrences(of: #"post_id\":1"#, with: #"post_id\":2"#),
            "not a publisher page"
        ] {
            XCTAssertNil(PublisherNarrationEvidence.confirmedEntry(entry, html: invalid))
        }
    }

    func testNarrationConfirmationCannotRestoreARemovedEntryOrOverwriteARefresh() throws {
        let store = try SQLiteSessionStore(path: temporary.appendingPathComponent("confirmation.sqlite").path)
        let original = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://captured.example/p/voiceover",
                                 title: "Article", bodyWordCount: 720)
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(original,
            html: String(decoding: Self.fixture("substack-voiceover-page.html"), as: UTF8.self)))
        try store.saveFeedEntry(original)
        try store.deleteFeedEntry(id: original.id)
        try PublisherNarrationEvidence.cache(confirmed, replacing: original, in: store)
        XCTAssertTrue(try store.loadFeedEntries(subscriptionId: "s").isEmpty, "unfollow cannot be undone by the old request")

        var refreshed = original
        refreshed.fullBody = "New edition from a later feed refresh."
        refreshed.state = .dismissed
        try store.saveFeedEntry(refreshed)
        try PublisherNarrationEvidence.cache(confirmed, replacing: original, in: store)
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: "s"), [refreshed])

        try store.saveFeedEntry(original)
        try PublisherNarrationEvidence.cache(confirmed, replacing: original, in: store)
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: "s"), [confirmed])
    }

    func testSubscriberFeedTextSurvivesSQLiteAndSuppliesArticleHandoff() throws {
        let path = temporary.appendingPathComponent("subscriber.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let body = String(repeating: "Subscriber article body unavailable on the public page. ", count: 90)
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://captured.example/p/private",
            audioURL: "https://recordings.example/private.mp3", title: "Private article", bodyWordCount: 720,
            fullBody: body, publisherNarrationConfirmed: true)
        try store.saveFeedEntry(entry)
        let reopened = try SQLiteSessionStore(path: path)
        let persisted = try XCTUnwrap(try reopened.loadFeedEntries(subscriptionId: "s").first)
        XCTAssertEqual(persisted, entry)
        let handoff = try XCTUnwrap(PublisherAudioDetector.articleHandoff(for: persisted))
        XCTAssertEqual(handoff.text, body)
        XCTAssertEqual(handoff.source.url, entry.canonicalURL)
        var missingBody = persisted
        missingBody.fullBody = nil
        XCTAssertNil(PublisherAudioDetector.articleHandoff(for: missingBody), "no body falls back to extraction")
    }

    func testWordCountIgnoresPunctuationOnlyTokens() {
        XCTAssertEqual(PublisherAudioDetector.wordCount("One, two — three.\n\n4 five"), 5)
        XCTAssertEqual(PublisherAudioDetector.wordCount("  "), 0)
    }

    // MARK: Feed entries and the record kind

    func testFeedEntriesKeepTheNewFieldsAndOldPayloadsStillDecode() throws {
        let store = try SQLiteSessionStore(path: temporary.appendingPathComponent("entries.sqlite").path)
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://example.com/p/1", audioURL: "https://example.com/1.mp3",
                              title: "Post", bodyWordCount: 720, fullBody: "Retained text", publisherPlatform: "substack", publisherNarrationConfirmed: true, audioDurationMs: 60_000)
        try store.saveFeedEntry(entry)
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: "s"), [entry])

        let old = Data(#"{"id":"e","subscriptionId":"s","canonicalURL":"https://example.com/p/1","title":"Post","state":"unseen"}"#.utf8)
        let decoded = try JSONDecoder().decode(FeedEntry.self, from: old)
        XCTAssertNil(decoded.publisherPlatform)
        XCTAssertNil(decoded.fullBody)
        XCTAssertNil(decoded.publisherNarrationConfirmed)
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
