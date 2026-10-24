import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
@testable import SessionKitPersistence
import SessionKitTestInputs

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
        let items = try Self.substackItems()
        let voiceover = try XCTUnwrap(items.first { $0.title == "The harbor in winter" })
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: voiceover.url, title: voiceover.title,
                              bodyWordCount: PublisherAudioDetector.bodyWordCount(of: voiceover), fullBody: voiceover.content)
        let page = try Self.fixture("substack-voiceover-page.html")
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(entry, html: String(decoding: page, as: UTF8.self)))
        XCTAssertEqual(PublisherAudioDetector.kind(of: confirmed), .articleWithPublisherAudio)
        XCTAssertEqual(confirmed.audioURL, "https://recordings.example/voiceover.mp3")
        XCTAssertEqual(PublisherAudioDetector.articleHandoff(for: confirmed)?.text, voiceover.content)
    }

    func testAnEpisodeWithShortShowNotesIsStillAPodcastEpisode() throws {
        let feed = try Self.fixture("substack-transcript-podcast.rss")
        let episode = try XCTUnwrap(try FeedParser().parse(data: feed).items.first)
        XCTAssertNotNil(episode.content)
        XCTAssertEqual(PublisherAudioDetector.kind(of: episode), .podcastEpisode)
        for item in try FeedParser().parse(data: Self.fixture("enclosure-only-episodes.rss")).items {
            XCTAssertEqual(PublisherAudioDetector.kind(of: item), .podcastEpisode, item.title)
        }
    }

    func testATextOnlyPostIsAnArticleWithoutAudio() throws {
        let items = try Self.substackItems()
        let post = try XCTUnwrap(items.first { $0.title == "Notes from the archive" })
        XCTAssertNil(post.audioURL)
        XCTAssertEqual(PublisherAudioDetector.kind(of: post), .article)
    }

    func testLongNotesOnAnEpisodeWhoseLinkIsItsAudioStayAPodcastEpisode() {
        let audio = "https://media.example.com/show/ep1.mp3"
        let page = "https://example.com/p/1"
        // Without the publisher's own word that this is narration, the notes' length decides nothing.
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: audio, pageURL: audio, bodyWordCount: 5_000), .podcastEpisode)
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: audio, pageURL: page, bodyWordCount: 5_000), .podcastEpisode,
                       "long notes alone are not narration")
        XCTAssertEqual(PublisherAudioDetector.kind(audioURL: "http://media.example.com/a.mp3", pageURL: page, bodyWordCount: 900), .article,
                       "a non-https enclosure isn't audio the app would play")
    }

    /// With narration confirmed, the calls above stop at the first guard. These reach the checks
    /// below it: the body must be long enough, and the post's page must not be the audio itself.
    func testConfirmedNarrationStillNeedsAFullBodyAndAPageOfItsOwn() {
        let audio = "https://media.example.com/show/ep1.mp3"
        let page = "https://example.com/p/1"
        func kind(audioURL: String = audio, pageURL: String = page, words: Int?) -> FeedEntryMediaKind {
            PublisherAudioDetector.kind(audioURL: audioURL, pageURL: pageURL, bodyWordCount: words, publisherNarrationConfirmed: true)
        }
        XCTAssertEqual(kind(words: PublisherAudioDetector.minimumBodyWords), .articleWithPublisherAudio)
        XCTAssertEqual(kind(words: 600), .articleWithPublisherAudio, "the line is 600 words and 600 is on the article side")
        XCTAssertEqual(kind(words: 599), .podcastEpisode, "one word short of a full post")
        XCTAssertEqual(kind(words: 0), .podcastEpisode)
        XCTAssertEqual(kind(words: nil), .podcastEpisode, "no body in the feed: nothing to import as an article")
        XCTAssertEqual(kind(pageURL: audio, words: 5_000), .podcastEpisode, "the page is the audio file itself")
        XCTAssertEqual(kind(pageURL: " \(audio) ", words: 5_000), .podcastEpisode, "the same link with spaces around it")
        XCTAssertEqual(kind(pageURL: "http://example.com/p/1", words: 5_000), .podcastEpisode, "a page the app would not open over https")
        XCTAssertEqual(kind(audioURL: "http://media.example.com/a.mp3", words: 5_000), .article, "an enclosure the app would not play")
        XCTAssertEqual(kind(audioURL: "", words: 5_000), .article)
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

    // MARK: Followed posts with only Substack's automatic voice (#1616)

    private func followedEntry(_ canonicalURL: String, words: Int = 720) -> FeedEntry {
        FeedEntry(id: "e", subscriptionId: "s", canonicalURL: canonicalURL, title: "Article", bodyWordCount: words, publisherPlatform: "substack")
    }

    /// The owner's call (2026-10-14): a followed post plays Substack's automatic voice when it has one, as a shared post does.
    func testAFollowedPostWithOnlyTheAutomaticVoiceKeepsItMarkedAsGenerated() throws {
        let html = String(decoding: try Self.fixture("substack-generated-voice-only-page.html"), as: UTF8.self)
        let entry = followedEntry("https://captured.example/p/generated-voice")
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(entry, html: html))
        XCTAssertEqual(confirmed.audioURL, "https://recordings.example/tts/en-US-AlloyTurboMultilingualNeural.mp3")
        XCTAssertEqual(confirmed.publisherNarrationConfirmed, true)
        XCTAssertEqual(confirmed.publisherNarrationGenerated, true)
        XCTAssertEqual(PublisherAudioDetector.kind(of: confirmed), .articleWithPublisherAudio, "an article with the audio beside it, not a podcast episode")
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: confirmed, itemId: "item"), PublisherAudio(
            itemId: "item", audioURL: "https://recordings.example/tts/en-US-AlloyTurboMultilingualNeural.mp3", durationMs: nil,
            detectedFrom: "substack_post_generated_voice"
        ))
    }

    func testAFollowedPostWithBothKeepsTheAuthorsVoiceover() throws {
        let html = String(decoding: try Self.fixture("substack-voiceover-and-generated-voice-page.html"), as: UTF8.self)
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(
            followedEntry("https://captured.example/p/voiceover-and-generated-voice"), html: html))
        XCTAssertEqual(confirmed.audioURL, "https://api.recordings.example/api/v1/audio/upload/11111111-2222-3333-4444-555555555555/src")
        XCTAssertEqual(confirmed.audioDurationMs, 1_136_378)
        XCTAssertNil(confirmed.publisherNarrationGenerated, "it is the author's voice")
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: confirmed, itemId: "item")?.detectedFrom, "substack_post_voiceover")
    }

    func testAFollowedPaidPostReadWithoutASubscriptionKeepsNothing() throws {
        let html = String(decoding: try Self.fixture("substack-paid-post-page.html"), as: UTF8.self)
        XCTAssertNil(PublisherNarrationEvidence.confirmedEntry(followedEntry("https://captured.example/p/paid-post"), html: html))
    }

    /// Neighbouring pages for the automatic voice: another post's page, a podcast post, an unfinished or unusable recording.
    func testTheAutomaticVoiceNeedsTheSamePostACompletedRecordingAndANewsletterPost() throws {
        let html = String(decoding: try Self.fixture("substack-generated-voice-only-page.html"), as: UTF8.self)
        let entry = followedEntry("https://captured.example/p/generated-voice")
        XCTAssertNotNil(PublisherNarrationEvidence.confirmedEntry(entry, html: html))
        for (name, invalid) in [
            ("another post's page", html.replacingOccurrences(of: "https://captured.example/p/generated-voice", with: "https://captured.example/p/other")),
            ("a podcast post", html.replacingOccurrences(of: "newsletter", with: "podcast")),
            ("still processing", html.replacingOccurrences(of: "completed", with: "processing")),
            ("not https", html.replacingOccurrences(of: "https://recordings.example", with: "http://recordings.example")),
            ("another post's recording", html.replacingOccurrences(of: #"post_id\":1"#, with: #"post_id\":2"#)),
            ("no audio address", html.replacingOccurrences(of: #"audio_url\":\"https://recordings.example/tts/en-US-AlloyTurboMultilingualNeural.mp3\""#, with: #"audio_url\":null"#)),
            ("not a publisher page", "not a publisher page")
        ] {
            XCTAssertNil(PublisherNarrationEvidence.confirmedEntry(entry, html: invalid), name)
        }
        XCTAssertNotEqual(html, html.replacingOccurrences(of: #"audio_url\":\"https://recordings.example/tts/en-US-AlloyTurboMultilingualNeural.mp3\""#, with: #"audio_url\":null"#),
                          "the edit above applies to the fixture")
    }

    /// A real podcast feed's episodes are not Substack posts with narration: with no page evidence they import as before.
    func testPodcastEpisodesAreUnchangedByTheAutomaticVoice() throws {
        let feed = try Self.fixture("substack-transcript-podcast.rss")
        let episode = try XCTUnwrap(try FeedParser().parse(data: feed).items.first)
        XCTAssertEqual(PublisherAudioDetector.kind(of: episode), .podcastEpisode)
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: episode.url, audioURL: episode.audioURL, title: episode.title,
                              bodyWordCount: PublisherAudioDetector.bodyWordCount(of: episode))
        XCTAssertNil(entry.publisherNarrationGenerated)
        XCTAssertNil(PublisherAudioDetector.publisherAudio(for: entry, itemId: "item"))
        let podcastPage = String(decoding: try Self.fixture("substack-generated-voice-only-page.html"), as: UTF8.self)
            .replacingOccurrences(of: "newsletter", with: "podcast")
        XCTAssertNil(PublisherNarrationEvidence.confirmedEntry(followedEntry("https://captured.example/p/generated-voice"), html: podcastPage))
    }

    func testTheGeneratedMarkSurvivesSQLiteAndOldEntriesDecodeWithoutIt() throws {
        let store = try SQLiteSessionStore(path: temporary.appendingPathComponent("generated.sqlite").path)
        let html = String(decoding: try Self.fixture("substack-generated-voice-only-page.html"), as: UTF8.self)
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(followedEntry("https://captured.example/p/generated-voice"), html: html))
        try store.saveFeedEntry(confirmed)
        let reopened = try SQLiteSessionStore(path: temporary.appendingPathComponent("generated.sqlite").path)
        XCTAssertEqual(try reopened.loadFeedEntries(subscriptionId: "s"), [confirmed])

        let old = Data(#"{"id":"e","subscriptionId":"s","canonicalURL":"https://example.com/p/1","title":"Post","state":"unseen","publisherNarrationConfirmed":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FeedEntry.self, from: old).publisherNarrationGenerated)
    }

    func testNarrationConfirmationCannotRestoreARemovedEntryOrOverwriteARefresh() throws {
        let store = try SQLiteSessionStore(path: temporary.appendingPathComponent("confirmation.sqlite").path)
        let original = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://captured.example/p/voiceover",
                                 title: "Article", bodyWordCount: 720)
        let html = String(decoding: try Self.fixture("substack-voiceover-page.html"), as: UTF8.self)
        let confirmed = try XCTUnwrap(PublisherNarrationEvidence.confirmedEntry(original, html: html))
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

    // MARK: How Following adds an entry (#641)

    /// #641: a publication followed as a podcast feed (it has some voiceovers) also has text-only
    /// posts. Adding one took the podcast path with the post's page as the "audio" and failed.
    func testATextOnlyPostOnAPodcastFeedImportsAsAnArticle() throws {
        let items = try Self.substackItems()
        let post = try XCTUnwrap(items.first { $0.title == "Notes from the archive" })
        XCTAssertNil(post.audioURL, "the feed lists it with an image enclosure only")
        let entry = FeedEntry(id: "text", subscriptionId: "s", canonicalURL: post.url, audioURL: post.audioURL, title: post.title,
                              bodyWordCount: PublisherAudioDetector.bodyWordCount(of: post), fullBody: post.content)
        XCTAssertTrue(FollowedEntryImportRoute.needsAudioLookup(for: entry, subscriptionKind: .podcastFeed), "it could be an older episode")
        XCTAssertEqual(FollowedEntryImportRoute.route(for: entry, subscriptionKind: .podcastFeed, audio: .noneInFeed), .article,
                       "the feed lists it with nothing to play: add its text")
    }

    func testEpisodesStillImportAsAudioIncludingOlderOnesSavedWithoutTheirEnclosure() throws {
        let feed = try Self.fixture("enclosure-only-episodes.rss")
        let item = try XCTUnwrap(try FeedParser().parse(data: feed).items.first)
        let audio = try XCTUnwrap(item.audioURL)
        let episode = FeedEntry(id: "episode", subscriptionId: "s", canonicalURL: item.url, audioURL: audio, title: item.title)
        XCTAssertEqual(FollowedEntryAudio.stored(in: episode), .found(audio))
        XCTAssertEqual(FollowedEntryImportRoute.route(for: episode, subscriptionKind: .podcastFeed, audio: .found(audio)), .episode(audioURL: audio))

        var older = episode
        older.audioURL = nil // saved before entries kept their enclosure
        XCTAssertEqual(FollowedEntryAudio.stored(in: older), .unknown)
        XCTAssertEqual(FollowedEntryImportRoute.route(for: older, subscriptionKind: .podcastFeed, audio: .found(audio)), .episode(audioURL: audio),
                       "the feed still lists its enclosure")
        XCTAssertEqual(FollowedEntryImportRoute.route(for: older, subscriptionKind: .podcastFeed, audio: .unknown), .episode(audioURL: item.url),
                       "gone from the feed: the podcast path tries its page, as before")
        XCTAssertEqual(FollowedEntryImportRoute.route(for: older, subscriptionKind: .podcastFeed, audio: .found(" ")), .episode(audioURL: item.url))
    }

    func testVoiceoversAndArticleFeedEntriesImportAsArticlesWithoutLookingForAudio() throws {
        let voiceover = FeedEntry(id: "v", subscriptionId: "s", canonicalURL: "https://publisher.example/p/post",
                                  audioURL: "https://publisher.example/post.mp3", title: "Post", bodyWordCount: 800,
                                  publisherNarrationConfirmed: true)
        XCTAssertTrue(voiceover.hasPublisherAudio)
        XCTAssertFalse(FollowedEntryImportRoute.needsAudioLookup(for: voiceover, subscriptionKind: .podcastFeed))
        XCTAssertEqual(FollowedEntryImportRoute.route(for: voiceover, subscriptionKind: .podcastFeed, audio: .stored(in: voiceover)), .article)

        let post = FeedEntry(id: "a", subscriptionId: "s", canonicalURL: "https://blog.example/p/post", audioURL: "https://blog.example/a.mp3", title: "Post")
        XCTAssertFalse(FollowedEntryImportRoute.needsAudioLookup(for: post, subscriptionKind: .articleFeed))
        XCTAssertEqual(FollowedEntryImportRoute.route(for: post, subscriptionKind: .articleFeed, audio: .stored(in: post)), .article)
    }

    // MARK: Fixtures

    private static func substackItems() throws -> [ParsedFeedItem] {
        try FeedParser().parse(data: fixture("substack-publisher-audio.rss")).items
    }

    private static func fixture(_ name: String) throws -> Data {
        try TestInputs.data(.contracts, "fixtures/feeds/\(name)")
    }
}
