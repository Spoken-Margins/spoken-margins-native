import XCTest
import SessionKit
import SessionKitPersistence
import SessionKitAudio
import SessionKitFeeds
import SessionKitSharing
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SourceLinkImportTests: XCTestCase {
    func testNetworkFailureShowsReadableMessageInsteadOfRawURLError() {
        let model = Gate1AppModel(
            sourceLinkResolver: ThrowingAppLinkResolver(error: URLError(.badServerResponse)),
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        XCTAssertFalse(model.importSourceLink(urlString: "https://example.com/missing-episode", sourceSurface: "paste"))

        let message = model.lastError
        XCTAssertEqual(message, "Source link import failed: The server couldn’t provide anything at that address. Check the link and try again.")
        XCTAssertFalse(message?.contains("NSURLErrorDomain") ?? true)
        XCTAssertEqual(Gate1AppModel.userFacingMessage(for: URLError(.timedOut)), "The request timed out. Please try again.")
        XCTAssertEqual(Gate1AppModel.userFacingMessage(for: URLError(.notConnectedToInternet)), "You appear to be offline. Check your connection and try again.")
    }

    #if canImport(UIKit)
    func testPasteAFeedLinkFillsTheFollowingFieldFromTheClipboard() {
        // #153: the empty Following screen's "Paste a feed link" only focused the field.
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let saved = UIPasteboard.general.string
        defer { UIPasteboard.general.string = saved }
        UIPasteboard.general.string = "Try this show: https://feeds.example.com/show.rss"
        XCTAssertTrue(model.pasteFollowedSourceFromClipboard())
        XCTAssertEqual(model.followedSourceURL, "https://feeds.example.com/show.rss")
        UIPasteboard.general.string = "no link here"
        XCTAssertFalse(model.pasteFollowedSourceFromClipboard())
        XCTAssertEqual(model.followedSourceURL, "https://feeds.example.com/show.rss")
    }
    #endif

    func testMiniPlayerNamesThePlayingItemWhileAnotherItemPageIsOpen() throws {
        // Seen on Build 29: browsing to another item while listening relabelled the mini player.
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let other = "item-browser-other-page"
        XCTAssertTrue(model.importBrowserText(BrowserTextHandoff(
            itemId: other,
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/other", title: "Another Page"),
            text: "Text of another page.",
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "browser_or_app")
        )))
        let playing = "item-pill"
        model.startItem(id: playing)
        XCTAssertEqual(model.snapshot.itemId, playing)
        let playingTitle = model.playbackItemHeaderTitle
        model.openItem(id: other)
        XCTAssertEqual(model.selectedItem.id, other)
        XCTAssertNotEqual(model.selectedItem.title, playingTitle)
        XCTAssertEqual(model.playbackItemHeaderTitle, playingTitle)
    }

    private var temporaryDirectories: [URL] = []

    // On a fresh simulator the first-use voice choice is still pending, and
    // start() and resumeSession() wait for it. A full run only passed because
    // earlier classes had made that choice, so a targeted T3 of this class
    // failed (#446). Every test starts with the choice made: the iOS voice.
    private static let firstUseVoiceKeys = [
        "supertonicTTSMigrationV1",
        "supertonicVoicePendingTermsV1",
        "ttsMode",
        "ttsVoiceSelection",
        SpokenMarginsTerms.acceptanceVersionKey,
        SpokenMarginsTerms.acceptanceDateKey
    ]
    private var priorFirstUseVoiceDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        priorFirstUseVoiceDefaults = [:]
        for key in Self.firstUseVoiceKeys {
            priorFirstUseVoiceDefaults[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        // What declineCurrentTerms() leaves behind after the pre-1.0 migration.
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.system.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("systemImmediate", forKey: "ttsMode")
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        let defaults = UserDefaults.standard
        for key in Self.firstUseVoiceKeys {
            if let value = priorFirstUseVoiceDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try super.tearDownWithError()
    }

    func testFeedEntryImportPreservesTitleAndSourceWithoutChangingActivePlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Model background tasks retain SQLite beyond this test; do not unlink its open WAL.
        let databaseURL = root.appending(path: "library.sqlite")
        let audioURL = "https://audio.example/episode.mp3"
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(requestId: "ignored", status: .playable, originalLink: SourceLink(url: audioURL, role: "discovery"), selectedCandidate: LinkResolutionCandidate(sourceLink: SourceLink(url: audioURL, role: "media"), title: "audio", durationMs: 300_000, audioURL: audioURL, confidence: 1)))
        let model = Gate1AppModel(sourceLinkResolver: resolver, audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let activeSession = model.snapshot.sessionId
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let subscription = FeedSubscription(id: "subscription", source: SourceIdentity(id: "source", kind: .podcastFeed, canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Actual Publisher"), lastRefreshAt: Date())
        try store.saveFeedSubscription(subscription)
        let entry = FeedEntry(id: "entry", subscriptionId: subscription.id, canonicalURL: "https://publisher.example/episode", audioURL: audioURL, title: "Actual episode title", author: "Actual author", summary: "00:00 Opening\n02:00 Discussion", publishedAt: Date(timeIntervalSince1970: 1_790_675_200), bodyWordCount: 900, fullBody: String(repeating: "Podcast transcript. ", count: 450), episodeGUID: "episode-42")
        try store.saveFeedEntry(entry)
        model.importFollowedSourceEntry(entry)
        try await waitFor("feed entry import") { model.libraryItems.contains { $0.title == entry.title } }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == entry.title })
        let persisted = try store.loadItem(id: row.id)
        XCTAssertNotNil(persisted.media, "a long podcast transcript must not replace playable episode media")
        XCTAssertEqual(persisted.sourceTitle, "Actual Publisher")
        XCTAssertEqual(persisted.sourceURL, subscription.source.canonicalURL)
        XCTAssertEqual(persisted.externalReference, entry.canonicalURL)
        XCTAssertEqual(persisted.author, "Actual author")
        // #177 audit: an episode added from a followed feed can be matched to a shared Margin by GUID.
        XCTAssertEqual(persisted.episodeGUID, "episode-42")
        XCTAssertEqual(persisted.showTitle, "Actual Publisher")
        XCTAssertEqual(persisted.publishedAt, ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_675_200)))
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: row.id)?.timeline.chapters.map(\.startMs), [0, 120_000])
        XCTAssertEqual(model.snapshot.sessionId, activeSession)
        XCTAssertEqual(model.selectedItem.id, "item-pill")

        // Two feed entries can resolve through the same generic CDN filename
        // (or even an enclosure endpoint). Their feed identities must remain
        // separate before the display title is applied to the stored item.
        let firstMap = ListeningMap(id: "first-entry-map", itemId: row.id, overview: "AI data centers", chapters: [])
        try store.saveListeningMap(firstMap)
        let secondEntry = FeedEntry(id: "second-entry", subscriptionId: subscription.id, canonicalURL: "https://publisher.example/second-episode", audioURL: audioURL, title: "End of history")
        try store.saveFeedEntry(secondEntry)
        model.importFollowedSourceEntry(secondEntry)
        try await waitFor("second feed entry import") { model.libraryItems.contains { $0.title == secondEntry.title } }
        let secondRow = try XCTUnwrap(model.libraryItems.first { $0.title == secondEntry.title })
        XCTAssertNotEqual(secondRow.id, row.id)
        XCTAssertNil(try store.loadListeningMap(itemId: secondRow.id))
        XCTAssertEqual(try store.loadListeningMap(itemId: row.id), firstMap)
        XCTAssertEqual(try store.loadItem(id: row.id).title, entry.title)
        XCTAssertEqual(model.snapshot.sessionId, activeSession)
        XCTAssertEqual(model.selectedItem.id, "item-pill")
    }

    /// #478: "Play now" on a Following entry adds it and starts it, so the listener hears audio after
    /// two taps (long-press, Play now). Adding alone starts nothing.
    func testPlayNowAddsAFollowedEpisodeAndStartsItButAddingAloneDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let databaseURL = root.appending(path: "library.sqlite")
        let audioURL = "https://audio.example/play-now.mp3"
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(requestId: "ignored", status: .playable, originalLink: SourceLink(url: audioURL, role: "discovery"), selectedCandidate: LinkResolutionCandidate(sourceLink: SourceLink(url: audioURL, role: "media"), title: "audio", durationMs: 300_000, audioURL: audioURL, confidence: 1)))
        let model = Gate1AppModel(sourceLinkResolver: resolver, audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let subscription = FeedSubscription(id: "subscription", source: SourceIdentity(id: "source", kind: .podcastFeed, canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Actual Publisher"), lastRefreshAt: Date())
        try store.saveFeedSubscription(subscription)
        let added = FeedEntry(id: "added-entry", subscriptionId: subscription.id, canonicalURL: "https://publisher.example/added", audioURL: audioURL, title: "Added only", bodyWordCount: 900, fullBody: String(repeating: "Podcast transcript. ", count: 450), episodeGUID: "added-1")
        let played = FeedEntry(id: "played-entry", subscriptionId: subscription.id, canonicalURL: "https://publisher.example/played", audioURL: audioURL, title: "Play now entry", bodyWordCount: 900, fullBody: String(repeating: "Podcast transcript. ", count: 450), episodeGUID: "played-1")
        try store.saveFeedEntry(added)
        try store.saveFeedEntry(played)

        model.importFollowedSourceEntry(added)
        try await waitFor("added entry import") { model.libraryItems.contains { $0.title == added.title } }
        XCTAssertNil(model.snapshot.sessionId, "adding alone starts nothing")

        model.importFollowedSourceEntry(played, playWhenFinished: true)
        try await waitFor("play now import", timeoutNanoseconds: 3_000_000_000) { model.snapshot.sessionId != nil }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == played.title })
        XCTAssertEqual(model.snapshot.itemId, row.id, "the entry that was imported is the one playing")
    }

    /// #2124: Play now on a followed post waits on a slow page fetch. If the listener starts another item
    /// meanwhile, the late fetch still adds the post but must not stop what they started.
    func testPlayNowOnAFollowedPostDoesNotTakeOverPlaybackStartedDuringItsFetch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let database = root.appendingPathComponent("late-play-now.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        let subscription = FeedSubscription(id: "s", source: SourceIdentity(id: "publication", kind: .articleFeed,
            canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"), lastRefreshAt: Date())
        let entry = FeedEntry(id: "slow-entry", subscriptionId: subscription.id,
            canonicalURL: "https://publisher.example/slow-post", title: "A slow post")
        try store.saveFeedSubscription(subscription)
        try store.saveFeedEntry(entry)
        let extractor = GatedFeedArticleExtractor(capture: BrowserTextHandoff(captureMode: .readablePage,
            source: BrowserTextSource(url: entry.canonicalURL, title: entry.title),
            text: "The slow post's body arrives after the listener has moved on."))
        model.readablePageExtractor = extractor

        model.importFollowedSourceEntry(entry, playWhenFinished: true)
        try await waitFor("the post's fetch to start") { extractor.callCount > 0 }
        model.startItem(id: "item-pill") // the listener starts something else while the fetch is out
        let started = try XCTUnwrap(model.snapshot.sessionId)

        extractor.open()
        try await waitFor("the late fetch to finish") { !model.importingFollowedSourceEntryIds.contains(entry.id) }
        XCTAssertTrue(model.libraryItems.contains { $0.title == entry.title }, "the post is still added to the Library")
        XCTAssertEqual(model.snapshot.sessionId, started, "the late Play now must not stop what the listener started")
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.selectedItem.id, "item-pill")
        model.endSession()
    }

    func testRedirectedFollowedArticleAddAndOpenKeepTheirSignalEntry() async throws {
        for openWhenFinished in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            temporaryDirectories.append(root)
            let database = root.appendingPathComponent("redirect.sqlite")
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
            model.resetAndSeed()
            let store = try SQLiteSessionStore(path: database.path)
            let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
            let signals = ListeningSignalsCoordinator(recorder: recorder, repository: { store })
            model.listeningSignals = signals
            model.startItem(id: "item-pill")
            let activeSession = model.snapshot.sessionId
            let subscription = FeedSubscription(id: "s", source: SourceIdentity(id: "publication", kind: .articleFeed,
                canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"), lastRefreshAt: Date())
            let entry = FeedEntry(id: "redirected-entry", subscriptionId: subscription.id,
                canonicalURL: "https://publisher.example/link", title: "A redirected article")
            try store.saveFeedSubscription(subscription)
            try store.saveFeedEntry(entry)
            let capture = BrowserTextHandoff(captureMode: .readablePage,
                source: BrowserTextSource(url: "https://destination.example/article", title: entry.title),
                text: "The extracted article body stays intact.")
            model.readablePageExtractor = RedirectedFeedArticleExtractor(capture: capture)
            model.importFollowedSourceEntry(entry, openWhenFinished: openWhenFinished)
            try await waitFor("redirected followed article import") { model.libraryItems.contains { $0.title == entry.title } }
            let row = try XCTUnwrap(model.libraryItems.first { $0.title == entry.title })
            let item = try store.loadItem(id: row.id)
            XCTAssertEqual(item.externalReference, capture.source.url, "the final URL stays the sharing identity")
            XCTAssertEqual(item.text, capture.text)
            XCTAssertEqual(model.snapshot.sessionId, activeSession)
            XCTAssertEqual(model.selectedItem.id, openWhenFinished ? item.id : "item-pill")
            signals.writtenMargin(itemId: item.id, text: "A note")
            let exported = await signals.exportFileURL()
            let rows = exported.map(ListeningSignalRecorder.read) ?? []
            XCTAssertEqual(rows.filter { $0.event.name == "margin" }.map { $0.item?.id }, [entry.id])
            model.endSession()
        }
    }

    func testFeedAliasesUseFinalResponseIdentityWithoutSelfLink() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AliasedFeedURLProtocol.self]
        let coordinator = FollowedSourceCoordinator(repository: InMemorySessionRepository(), session: URLSession(configuration: configuration), signals: .app)
        let candidates = try await coordinator.discover(urlString: "https://example.com/article", requiringItemMembership: true)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.source.canonicalURL, "https://example.com/canonical-feed")
        let subscription = try await coordinator.follow(urlString: "https://example.com/rss")
        XCTAssertEqual(subscription.source.id, candidates.first?.source.id)
    }

    /// #545: a Substack post with a voiceover was saved like an episode, so adding it made a podcast
    /// item with no text. Following the feed now records each entry's body length and duration, and
    /// the voiceover entry is the only one that imports as an article with publisher audio.
    func testFollowingAPublicationWithVoiceoversMarksOnlyThePostsWithAFullBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceoverFeedURLProtocol.self]
        let repository = InMemorySessionRepository()
        let coordinator = FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: .app)

        let subscription = try await coordinator.follow(urlString: "https://voiceovers.example/feed")

        XCTAssertEqual(subscription.source.kind, .podcastFeed, "a feed with audio is still followed as it was")
        let entries = try repository.loadFeedEntries(subscriptionId: subscription.id)
        let post = try XCTUnwrap(entries.first { $0.title == "A post with a voiceover" })
        let episode = try XCTUnwrap(entries.first { $0.title == "An episode" })
        XCTAssertGreaterThanOrEqual(post.bodyWordCount ?? 0, 700)
        XCTAssertEqual(post.audioDurationMs, 1_312_000)
        XCTAssertFalse(post.hasPublisherAudio, "length alone is ambiguous")
        let confirmed = await coordinator.publisherAudioEntry(for: post, trigger: .listenerAction)
        XCTAssertTrue(confirmed.hasPublisherAudio)
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: confirmed, itemId: "item")?.audioURL, "https://cdn.voiceovers.example/post.mp3")
        XCTAssertFalse(episode.hasPublisherAudio, "an episode with short notes imports as audio, as before")
        XCTAssertNil(PublisherAudioDetector.publisherAudio(for: episode, itemId: "item"))
    }

    /// #641: following a publication with some voiceovers makes it a podcast feed, and Add on one
    /// of its text-only posts took the podcast path with the post's page as the audio, which
    /// failed. With nothing to play, even after rechecking the feed, the post imports as an article.
    func testATextOnlyPostOnAFollowedPodcastFeedImportsAsAnArticle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceoverFeedURLProtocol.self]
        let repository = InMemorySessionRepository()
        let coordinator = FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: .app)
        let subscription = try await coordinator.follow(urlString: "https://voiceovers.example/feed")
        XCTAssertEqual(subscription.source.kind, .podcastFeed)
        let entries = try repository.loadFeedEntries(subscriptionId: subscription.id)

        let post = try XCTUnwrap(entries.first { $0.title == "A text-only post" })
        XCTAssertNil(post.audioURL)
        let postRoute = try await coordinator.importRoute(for: post, subscriptionKind: subscription.source.kind)
        XCTAssertEqual(postRoute, .article)

        // An older episode saved without its enclosure still finds it in the feed and imports as audio.
        var episode = try XCTUnwrap(entries.first { $0.title == "An episode" })
        episode.audioURL = nil
        try repository.saveFeedEntry(episode)
        let episodeRoute = try await coordinator.importRoute(for: episode, subscriptionKind: subscription.source.kind)
        XCTAssertEqual(episodeRoute, .episode(audioURL: "https://cdn.voiceovers.example/episode.mp3"))

        // One no longer in the feed may still be an episode: the podcast path tries its page, as before.
        let gone = FeedEntry(id: "gone", subscriptionId: subscription.id, canonicalURL: "https://voiceovers.example/p/gone", title: "Gone")
        let goneRoute = try await coordinator.importRoute(for: gone, subscriptionKind: subscription.source.kind)
        XCTAssertEqual(goneRoute, .episode(audioURL: gone.canonicalURL))
    }

    func testPublisherNarrationImportsSubscriberFeedBodyWithoutPublicPageExtraction() async throws {
        for openWhenFinished in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let databaseURL = root.appendingPathComponent("subscriber.sqlite")
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
            model.resetAndSeed()
            model.startItem(id: "item-pill")
            let activeSession = model.snapshot.sessionId
            let extractor = RefusingPublisherPageExtractor()
            model.readablePageExtractor = extractor
            let store = try SQLiteSessionStore(path: databaseURL.path)
            let subscription = FeedSubscription(id: "s", source: SourceIdentity(id: "publication", kind: .podcastFeed,
                canonicalURL: "https://publisher.example/private-feed", host: "publisher.example", title: "Publisher"), lastRefreshAt: Date())
            try store.saveFeedSubscription(subscription)
            let sentences = String(repeating: "This subscriber article is available in the feed only. ", count: 90)
            let html = "<p>Don&#8217;t stop. &ldquo;Listen&rdquo; &copy; 2026.</p><p>\(sentences)</p>"
            let feed = "<rss><channel><item><title>Private publisher narration</title><link>https://publisher.example/p/private</link><content:encoded xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"><![CDATA[\(html)]]></content:encoded></item></channel></rss>"
            let parsed = try FeedParser().parse(data: Data(feed.utf8), contentType: "application/rss+xml")
            let body = try XCTUnwrap(parsed.items.first?.content)
            let expected = "Don’t stop. “Listen” © 2026. " + sentences.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = FeedEntry(id: "private-post", subscriptionId: "s", canonicalURL: "https://publisher.example/p/private",
                audioURL: "https://publisher.example/private.mp3", title: "Private publisher narration", bodyWordCount: 810,
                fullBody: body, publisherNarrationConfirmed: true, audioDurationMs: 60_000)
            try store.saveFeedEntry(entry)
            model.importFollowedSourceEntry(entry, openWhenFinished: openWhenFinished)
            try await waitFor("subscriber feed article import") {
                (try? store.loadFeedEntries(subscriptionId: "s").first?.state) == .imported
            }
            let row = try XCTUnwrap(model.libraryItems.first { $0.title == entry.title })
            let item = try store.loadItem(id: row.id)
            XCTAssertEqual(item.mediaType, "text")
            XCTAssertEqual(item.text, expected, "Add and open must import decoded feed text")
            XCTAssertNil(item.media)
            XCTAssertEqual(try store.loadPublisherAudio(itemId: item.id)?.audioURL, entry.audioURL)
            let followed = try XCTUnwrap(model.diagnostics["followedPublisherAudio"], "#2024: the followed path says what it kept")
            XCTAssertTrue(followed.hasPrefix("\(item.id): ") && followed.hasSuffix("; record=saved"), followed)
            XCTAssertEqual(extractor.calls, 0, "a public 403/teaser must never replace accessible feed text")
            XCTAssertEqual(model.snapshot.sessionId, activeSession)
            XCTAssertEqual(model.selectedItem.id, openWhenFinished ? item.id : "item-pill")
        }
    }

    /// #2368: "Add every new item" imports a Substack post nobody opened. It must read the feed's text and never
    /// load the post page, neither for the voiceover lookup nor for the article; without feed text it waits for a tap.
    func testABackgroundSubstackImportNeverLoadsThePostPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("background-substack.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let extractor = RefusingPublisherPageExtractor()
        model.readablePageExtractor = extractor
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let subscription = FeedSubscription(id: "s", source: SourceIdentity(id: "zvi", kind: .articleFeed,
            canonicalURL: "https://thezvi.substack.com/feed", host: "thezvi.substack.com", title: "Zvi"), lastRefreshAt: Date())
        try store.saveFeedSubscription(subscription)
        let body = String(repeating: "A free post, full text in the feed. ", count: 120)
        let withBody = FeedEntry(id: "with-body", subscriptionId: "s", canonicalURL: "https://thezvi.substack.com/p/with-body",
            title: "With body", bodyWordCount: 720, fullBody: body, publisherPlatform: "substack")
        let withoutBody = FeedEntry(id: "no-body", subscriptionId: "s", canonicalURL: "https://thezvi.substack.com/p/no-body",
            title: "No body", bodyWordCount: 720, publisherPlatform: "substack")
        try store.saveFeedEntry(withBody)
        try store.saveFeedEntry(withoutBody)

        model.importFollowedSourceEntry(withoutBody, startedByListener: false)
        model.importFollowedSourceEntry(withBody, startedByListener: false)
        try await waitFor("background feed-text import") {
            (try? store.loadFeedEntries(subscriptionId: "s").first { $0.id == "with-body" }?.state) == .imported
        }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == withBody.title })
        XCTAssertEqual(try store.loadItem(id: row.id).text, body.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNil(model.libraryItems.first { $0.title == withoutBody.title }, "no feed text: wait for the listener")
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: "s").first { $0.id == "no-body" }?.state, .unseen)
        XCTAssertEqual(extractor.calls, 0, "the post page was never loaded")
        XCTAssertEqual(model.diagnostics["followedPublisherAudio"]?.contains("deferred_until_opened"), true)
    }

    /// #2368: the page a background import skipped is read the first time the listener opens the item, and only then.
    /// Not at import, and not again by another background refresh.
    func testABackgroundSubstackImportLooksUpItsVoiceoverWhenTheListenerOpensIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("background-substack-open.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.readablePageExtractor = RefusingPublisherPageExtractor()
        var fetched: [URL] = []
        model.sharedLinkVoiceover.fetchPage = { url in
            fetched.append(url)
            return (html: "<html><head></head></html>", finalURL: url)
        }
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveFeedSubscription(FeedSubscription(id: "s", source: SourceIdentity(id: "zvi", kind: .articleFeed,
            canonicalURL: "https://thezvi.substack.com/feed", host: "thezvi.substack.com", title: "Zvi"), lastRefreshAt: Date()))
        let body = String(repeating: "A free post, full text in the feed. ", count: 120)
        let entry = FeedEntry(id: "with-body", subscriptionId: "s", canonicalURL: "https://thezvi.substack.com/p/with-body",
            title: "With body", bodyWordCount: 720, fullBody: body, publisherPlatform: "substack")
        try store.saveFeedEntry(entry)

        model.importFollowedSourceEntry(entry, startedByListener: false)
        try await waitFor("background feed-text import") {
            (try? store.loadFeedEntries(subscriptionId: "s").first?.state) == .imported
        }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == entry.title })
        XCTAssertEqual(fetched, [], "importing nobody opened reads no page")

        model.openItem(id: row.id)
        try await waitFor("the lookup on open") { fetched.count == 1 }
        XCTAssertEqual(fetched.first?.absoluteString, entry.canonicalURL)
        model.openItem(id: row.id)
        XCTAssertEqual(fetched.count, 1, "opening it again in the same launch does not read the page again")
    }

    func testConfirmedNarrationWithoutStoredBodyUsesTheArticleExtractor() async throws {
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://publisher.example/p/article",
            audioURL: "https://publisher.example/recording.mp3", title: "Article", bodyWordCount: 720,
            publisherNarrationConfirmed: true)
        let expected = BrowserTextHandoff(captureMode: .readablePage,
            source: BrowserTextSource(url: entry.canonicalURL, title: entry.title), text: "Extracted body.")
        let extractor = RefusingPublisherPageExtractor(result: expected)
        var diagnostics: [String: String] = [:]
        let result = try await FollowedArticleImport.handoff(for: entry, url: XCTUnwrap(URL(string: entry.canonicalURL)),
            using: extractor, record: { diagnostics = $0 })
        XCTAssertEqual(result, expected)
        XCTAssertEqual(extractor.calls, 1)
        XCTAssertEqual(diagnostics["followedArticleExtractor"], "unauthenticated-page")
    }

    func testFollowedSourceAcceptsLargeFeedAndRetainsOnlyNewestTwentyFiveSuggestions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LargePodcastFeedURLProtocol.self]
        let repository = InMemorySessionRepository()
        let coordinator = FollowedSourceCoordinator(
            repository: repository,
            session: URLSession(configuration: configuration),
            signals: .app
        )

        let subscription = try await coordinator.follow(urlString: "https://example.com/feed.json")

        XCTAssertEqual(subscription.source.kind, .podcastFeed)
        XCTAssertEqual(subscription.source.title, "Large Podcast")
        var entries = try repository.loadFeedEntries(subscriptionId: subscription.id)
        XCTAssertEqual(entries.count, FollowedSourceCoordinator.maximumRetainedSuggestionsPerFeed)
        XCTAssertEqual(Set(entries.map(\.title)), Set((6...30).map { "Episode \($0)" }))
        XCTAssertTrue(entries.allSatisfy { $0.audioURL?.hasPrefix("https://cdn.example.com/") == true })

        var legacyEpisode = try XCTUnwrap(entries.first(where: { $0.title == "Episode 30" }))
        legacyEpisode.audioURL = nil
        try repository.saveFeedEntry(legacyEpisode)

        let recoveredAudioURL = try await coordinator.playableAudioURL(for: legacyEpisode)

        XCTAssertEqual(recoveredAudioURL, "https://cdn.example.com/episode-30.mp3")
        XCTAssertEqual(
            try repository.loadFeedEntries(subscriptionId: subscription.id)
                .first(where: { $0.id == legacyEpisode.id })?.audioURL,
            recoveredAudioURL
        )

        try repository.saveFeedEntry(FeedEntry(
            id: "legacy-unseen",
            subscriptionId: subscription.id,
            canonicalURL: "https://example.com/episodes/legacy-unseen",
            title: "Legacy Unseen",
            publishedAt: .distantPast,
            state: .unseen
        ))
        try repository.saveFeedEntry(FeedEntry(
            id: "legacy-dismissed",
            subscriptionId: subscription.id,
            canonicalURL: "https://example.com/episodes/legacy-dismissed",
            title: "Legacy Dismissed",
            publishedAt: .distantPast,
            state: .dismissed
        ))
        try repository.saveFeedEntry(FeedEntry(
            id: "legacy-imported",
            subscriptionId: subscription.id,
            canonicalURL: "https://example.com/episodes/legacy-imported",
            title: "Legacy Imported",
            publishedAt: .distantPast,
            state: .imported
        ))

        _ = try await coordinator.follow(urlString: "https://example.com/feed.json")

        entries = try repository.loadFeedEntries(subscriptionId: subscription.id)
        XCTAssertFalse(entries.contains(where: { $0.id == "legacy-unseen" }))
        XCTAssertTrue(entries.contains(where: { $0.id == "legacy-dismissed" }))
        XCTAssertTrue(entries.contains(where: { $0.id == "legacy-imported" }))
        let visibleEntries = try await coordinator.entries()
        XCTAssertEqual(visibleEntries.count, FollowedSourceCoordinator.maximumRetainedSuggestionsPerFeed)
    }

    func testSourceLinkURLParsesHandoff() throws {
        let handoff = SourceLinkHandoff(
            id: "source-link-url-test",
            inputURL: "https://feeds.example.com/show.xml",
            sourceSurface: "paste",
            startSession: false
        )

        let parsed = try XCTUnwrap(SourceLinkHandoffURL.handoff(from: SourceLinkHandoffURL.url(for: handoff)))

        XCTAssertEqual(parsed.inputURL, "https://feeds.example.com/show.xml")
        XCTAssertEqual(parsed.sourceSurface, "paste")
        XCTAssertEqual(parsed.startSession, false)
    }

    func testShareRepresentationAcceptsObjectiveCURLVendedBySafari() throws {
        let expected = try XCTUnwrap(URL(string: "https://example.com/report.pdf"))
        let representation: Any = expected as NSURL

        XCTAssertEqual(SourceLinkShareRepresentation.url(from: representation), expected)
    }

    func testSafariPDFShareHandsOffThePDFBeforeItsURL() throws {
        // #271: PubMed Central answers a re-download of the link with an HTML
        // page, so the PDF Safari already has must be tried first.
        let provider = makeSharedPDFProvider(url: Self.pmcPDFURL)

        let identifiers = rankedShareIdentifiers([provider])

        XCTAssertEqual(identifiers.first, ShareSheetRepresentationOrder.pdfIdentifier)
        let pdfIndex = try XCTUnwrap(identifiers.firstIndex(of: ShareSheetRepresentationOrder.pdfIdentifier))
        let urlIndex = try XCTUnwrap(
            identifiers.firstIndex(of: ShareSheetRepresentationOrder.urlIdentifier),
            "The URL must stay as the fallback"
        )
        XCTAssertLessThan(pdfIndex, urlIndex)
    }

    func testSafariPDFShareOnSeparateAttachmentsHandsOffThePDFFirst() throws {
        let linkProvider = NSItemProvider(object: Self.pmcPDFURL as NSURL)
        let pdfProvider = makeSharedPDFProvider(url: nil)

        let candidates = ShareSheetRepresentationOrder.candidates(
            from: [linkProvider, pdfProvider],
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        )

        let first = try XCTUnwrap(candidates.first)
        XCTAssertTrue(first.provider === pdfProvider)
        XCTAssertEqual(first.identifier, ShareSheetRepresentationOrder.pdfIdentifier)
        XCTAssertTrue(candidates.contains {
            $0.provider === linkProvider && $0.identifier == ShareSheetRepresentationOrder.urlIdentifier
        })
    }

    func testSafariWebPageShareStillPrefersTheReadablePage() throws {
        let provider = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com/article")) as NSURL)
        provider.registerItem(forTypeIdentifier: ShareSheetRepresentationOrder.propertyListIdentifier) { completion, _, _ in
            completion?(["NSExtensionJavaScriptPreprocessingResultsKey": ["title": "Article"]] as NSDictionary, nil)
        }

        let identifiers = rankedShareIdentifiers([provider])

        XCTAssertEqual(identifiers.first, ShareSheetRepresentationOrder.propertyListIdentifier)
        XCTAssertFalse(identifiers.contains(ShareSheetRepresentationOrder.pdfIdentifier))
    }

    func testSafariPageSentPDFBytesAreUsedWithTheLinksFileName() throws {
        // #271's T4: Safari offered no PDF attachment, only the page results, so the PDF
        // comes from the bytes the preprocessor read in the page.
        let pdf = Data("%PDF-1.7 F1000Research 12:1146".utf8)
        let results: [String: Any] = [
            "documentURL": Self.pmcPDFURL.absoluteString,
            "isPDFDocument": true,
            SourceLinkShareRepresentation.pagePDFKey: pdf.base64EncodedString()
        ]

        let pagePDF = try XCTUnwrap(SourceLinkShareRepresentation.pagePDF(fromPageResults: results))

        XCTAssertEqual(pagePDF.data, pdf)
        XCTAssertEqual(pagePDF.suggestedFilename, "f1000research-12-157633.pdf")
        let copied = try makePayloadStore().savePDF(data: pagePDF.data, suggestedFilename: pagePDF.suggestedFilename)
        XCTAssertEqual(copied.lastPathComponent, "f1000research-12-157633.pdf")
    }

    func testSafariPageResultsOnASeparateAttachmentComeBeforeTheLink() throws {
        // #271 audit: with the link and the page results on separate attachments, the
        // page results (which can carry the PDF's bytes) must be tried before the link.
        let linkProvider = NSItemProvider(object: Self.pmcPDFURL as NSURL)
        let pageProvider = makePageResultsProvider(pdf: nil)

        let candidates = ShareSheetRepresentationOrder.candidates(
            from: [linkProvider, pageProvider],
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        )

        let pageIndex = try XCTUnwrap(candidates.firstIndex {
            $0.provider === pageProvider && $0.identifier == ShareSheetRepresentationOrder.propertyListIdentifier
        })
        let linkIndex = try XCTUnwrap(candidates.firstIndex {
            $0.provider === linkProvider && $0.identifier == ShareSheetRepresentationOrder.urlIdentifier
        })
        XCTAssertLessThan(pageIndex, linkIndex)
    }

    func testSafariPDFShareTriesThePageResultsBeforeTheLink() throws {
        let provider = makeSharedPDFProvider(url: Self.pmcPDFURL)
        provider.registerItem(forTypeIdentifier: ShareSheetRepresentationOrder.propertyListIdentifier) { completion, _, _ in
            completion?([:] as NSDictionary, nil)
        }

        let identifiers = rankedShareIdentifiers([provider])

        let pageIndex = try XCTUnwrap(identifiers.firstIndex(of: ShareSheetRepresentationOrder.propertyListIdentifier))
        let urlIndex = try XCTUnwrap(identifiers.firstIndex(of: ShareSheetRepresentationOrder.urlIdentifier))
        XCTAssertLessThan(pageIndex, urlIndex)
        XCTAssertEqual(identifiers.last, ShareSheetRepresentationOrder.urlIdentifier)
    }

    func testPageBytesOnALaterAttachmentWinOverAnEarlierLink() throws {
        // #271 audit: a link found first (page results without bytes, or a URL) waits
        // while other attachments are untried, so the PDF bytes become a local file.
        let pdf = Data("%PDF-1.7 PubMed Central".utf8)
        let linkOnlyPage = makePageResultsProvider(pdf: nil)
        let bytesPage = makePageResultsProvider(pdf: pdf)
        let linkProvider = NSItemProvider(object: Self.pmcPDFURL as NSURL)
        let candidates = ShareSheetRepresentationOrder.candidates(
            from: [linkProvider, linkOnlyPage, bytesPage],
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        )
        let store = makePayloadStore()

        let handoff = try firstShareHandoff(candidates, store: store)

        XCTAssertEqual(handoff.surface, "share_sheet_pdf_file")
        XCTAssertTrue(store.isManagedPDFURL(handoff.url))
        XCTAssertEqual(try Data(contentsOf: handoff.url), pdf)
    }

    func testLinkIsStillHandedOffWhenNoAttachmentCarriesThePDF() throws {
        let linkProvider = NSItemProvider(object: Self.pmcPDFURL as NSURL)
        let pageProvider = makePageResultsProvider(pdf: nil)
        let candidates = ShareSheetRepresentationOrder.candidates(
            from: [linkProvider, pageProvider],
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        )

        let handoff = try firstShareHandoff(candidates, store: makePayloadStore())

        XCTAssertEqual(handoff.surface, "share_sheet_pdf")
        XCTAssertEqual(handoff.url, Self.pmcPDFURL)
    }

    func testLinkFoundBeforeAnAttachmentThatYieldsNothingIsStillHandedOff() throws {
        // The link waits while the second attachment is tried; when that yields nothing, the kept
        // link is what the share hands off, not a failure (#271, #1049).
        let linkOnlyPage = makePageResultsProvider(pdf: nil)
        let emptyPage = NSItemProvider()
        emptyPage.registerItem(forTypeIdentifier: ShareSheetRepresentationOrder.propertyListIdentifier) { completion, _, _ in
            completion?([:] as NSDictionary, nil)
        }
        let candidates = ShareSheetRepresentationOrder.candidates(
            from: [linkOnlyPage, emptyPage],
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        )
        XCTAssertEqual(candidates.map(\.identifier), [
            ShareSheetRepresentationOrder.propertyListIdentifier, ShareSheetRepresentationOrder.propertyListIdentifier
        ])

        let handoff = try firstShareHandoff(candidates, store: makePayloadStore())

        XCTAssertEqual(handoff.surface, "share_sheet_pdf")
        XCTAssertEqual(handoff.url, Self.pmcPDFURL)
    }

    func testPDFRepresentationThatLoadsAsALinkKeepsItAsTheLastFallback() throws {
        // #271 audit on 1c86dee: an attachment offering only com.adobe.pdf can load as an
        // https link. With no file or bytes anywhere, that link must still be handed off.
        XCTAssertEqual(SourceLinkShareRepresentation.pdfFallbackLink(from: Self.pmcPDFURL as NSURL), Self.pmcPDFURL)
        XCTAssertNil(SourceLinkShareRepresentation.pdfFallbackLink(from: URL(fileURLWithPath: "/tmp/shared.pdf")))
        XCTAssertNil(SourceLinkShareRepresentation.pdfFallbackLink(from: URL(string: "http://example.com/report.pdf")))
        XCTAssertNil(SourceLinkShareRepresentation.pdfFallbackLink(from: Data("%PDF-1.7".utf8)))

        let pdfOnly = NSItemProvider()
        pdfOnly.registerItem(forTypeIdentifier: ShareSheetRepresentationOrder.pdfIdentifier) { completion, _, _ in
            completion?(Self.pmcPDFURL as NSURL, nil)
        }
        let candidates = ShareSheetRepresentationOrder.candidates(
            from: [pdfOnly],
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        )
        XCTAssertEqual(candidates.map(\.identifier), [ShareSheetRepresentationOrder.pdfIdentifier])

        let handoff = try firstShareHandoff(candidates, store: makePayloadStore())

        XCTAssertEqual(handoff.surface, "share_sheet_pdf")
        XCTAssertEqual(handoff.url, Self.pmcPDFURL)
    }

    func testSafariPageResultsWithoutPDFBytesFallBackToTheLink() {
        let html = Data("<html>Preparing to download</html>".utf8).base64EncodedString()

        XCTAssertNil(SourceLinkShareRepresentation.pagePDF(fromPageResults: ["documentURL": Self.pmcPDFURL.absoluteString]))
        XCTAssertNil(SourceLinkShareRepresentation.pagePDF(fromPageResults: [SourceLinkShareRepresentation.pagePDFKey: html]))
        XCTAssertNil(SourceLinkShareRepresentation.pagePDF(fromPageResults: [SourceLinkShareRepresentation.pagePDFKey: "not base64"]))
    }

    func testSharedTextIsHandedOffOnlyWhenNothingElseYieldsAndALinkBeatsIt() {
        // Plain text another app shared waits behind every other candidate, links included (#662).
        let textThenNothing: [ShareSheetCandidateOutcome<String>] = [.sharedText("text"), .nothing]
        XCTAssertEqual(walkedShare(textThenNothing), "text", "text is used once nothing else yields")

        let textLinkThenText: [ShareSheetCandidateOutcome<String>] = [.sharedText("first text"), .link("link"), .sharedText("second text")]
        XCTAssertEqual(walkedShare(textLinkThenText), "link", "a link found in the share beats its text")

        let textThenContent: [ShareSheetCandidateOutcome<String>] = [.sharedText("text"), .content("file")]
        XCTAssertEqual(walkedShare(textThenContent), "file", "content found after the text still wins")

        let twoTexts: [ShareSheetCandidateOutcome<String>] = [.sharedText("first text"), .sharedText("second text")]
        XCTAssertEqual(walkedShare(twoTexts), "first text", "the first text is the one kept")

        XCTAssertNil(walkedShare([.nothing, .nothing]), "nothing yielded means nothing is handed off")
    }

    /// Runs the share walk over canned outcomes, one per candidate, and returns what it handed off.
    private func walkedShare(_ outcomes: [ShareSheetCandidateOutcome<String>]) -> String? {
        let handedOff = WalkedShare()
        ShareSheetCandidateWalk.run(
            Array(outcomes.indices),
            identifier: { outcomes[$0].isLinkOutcome ? ShareSheetRepresentationOrder.urlIdentifier : "public.plain-text" },
            load: { index, report in report(outcomes[index]) },
            completion: { result in
                if case .success(let value)? = result { handedOff.value = value }
            }
        )
        return handedOff.value
    }

    private static let pmcPDFURL = URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC13305550/pdf/f1000research-12-157633.pdf")!

    private func makeSharedPDFProvider(url: URL?) -> NSItemProvider {
        let provider = url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: ShareSheetRepresentationOrder.pdfIdentifier,
            visibility: .all
        ) { completion in
            completion(Data("%PDF-1.7 shared from Safari".utf8), nil)
            return nil
        }
        return provider
    }

    private func makePageResultsProvider(pdf: Data?) -> NSItemProvider {
        var results: [String: Any] = ["documentURL": Self.pmcPDFURL.absoluteString, "isPDFDocument": true]
        results[SourceLinkShareRepresentation.pagePDFKey] = pdf?.base64EncodedString()
        let item = ["NSExtensionJavaScriptPreprocessingResultsKey": results] as NSDictionary
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: ShareSheetRepresentationOrder.propertyListIdentifier) { completion, _, _ in
            completion?(item, nil)
        }
        return provider
    }

    /// Runs the share extension's own walk (`ShareSheetCandidateWalk`, #1049) over the candidates, loading
    /// each real provider and reading what it carries the way the extension reads the same items: page
    /// results with the PDF's bytes become a local copy (`share_sheet_pdf_file`), and a web URL, page results
    /// without bytes, or a PDF representation that loads as a URL become a link (`share_sheet_pdf`). The walk,
    /// not this helper, decides which one is handed off.
    private func firstShareHandoff(
        _ candidates: [ShareSheetRepresentationOrder.Candidate<NSItemProvider>],
        store: SourceLinkHandoffStore
    ) throws -> (url: URL, surface: String) {
        let loaded = expectation(description: "share walk finished")
        let outcome = ShareWalkResult()
        let store = SharedPDFStore(store: store)
        ShareSheetCandidateWalk.run(
            candidates.map { SharedCandidate(provider: $0.provider, identifier: $0.identifier) },
            identifier: \.identifier,
            load: { candidate, report in
                candidate.provider.loadItem(forTypeIdentifier: candidate.identifier, options: nil) { item, _ in
                    report(Self.shareOutcome(of: item, identifier: candidate.identifier, store: store))
                }
            },
            resume: { next in DispatchQueue.main.async(execute: next) },
            completion: { result in
                outcome.set(result)
                loaded.fulfill()
            }
        )
        wait(for: [loaded], timeout: 5)
        return try XCTUnwrap(outcome.result, "no candidate was handed off").get()
    }

    nonisolated private static func shareOutcome(
        of item: NSSecureCoding?,
        identifier: String,
        store: SharedPDFStore
    ) -> ShareSheetCandidateOutcome<(url: URL, surface: String)> {
        if identifier == ShareSheetRepresentationOrder.pdfIdentifier {
            return SourceLinkShareRepresentation.pdfFallbackLink(from: item).map { .link(($0, "share_sheet_pdf")) } ?? .nothing
        }
        if let page = (item as? NSDictionary)?["NSExtensionJavaScriptPreprocessingResultsKey"] as? [String: Any] {
            if let pagePDF = SourceLinkShareRepresentation.pagePDF(fromPageResults: page) {
                do {
                    return .content((try store.store.savePDF(data: pagePDF.data, suggestedFilename: pagePDF.suggestedFilename), "share_sheet_pdf_file"))
                } catch {
                    return .failed(error)
                }
            }
            let link = (page["documentURL"] as? String).flatMap(URL.init(string:))
            return link.map { .link(($0, "share_sheet_pdf")) } ?? .nothing
        }
        return SourceLinkShareRepresentation.url(from: item).map { .link(($0, "share_sheet_pdf")) } ?? .nothing
    }

    private func rankedShareIdentifiers(_ providers: [NSItemProvider]) -> [String] {
        ShareSheetRepresentationOrder.candidates(
            from: providers,
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { _, _ in [] }
        ).map(\.identifier)
    }

    func testSourceLinkPayloadStoreRoundTripsAndDeletes() throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "payload-source-link",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "share_sheet",
            startSession: true
        )

        try store.save(handoff)
        XCTAssertEqual(try store.handoff(payloadID: handoff.id), handoff)
        try store.deletePayload(payloadID: handoff.id)

        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(handoff.id))
        }
    }

    func testSourceLinkStoreCopiesAndDeletesManagedPDF() throws {
        let store = makePayloadStore()
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-shared-pdf-source-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(sourceDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("Readable Report.pdf")
        try Data("%PDF-1.7 test".utf8).write(to: source)

        let copied = try store.savePDF(from: source, suggestedFilename: "Readable Report.pdf")

        XCTAssertTrue(store.isManagedPDFURL(copied))
        XCTAssertEqual(copied.lastPathComponent, "Readable Report.pdf")
        XCTAssertEqual(try Data(contentsOf: copied), Data("%PDF-1.7 test".utf8))
        store.deleteManagedPDF(at: copied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testSourceLinkStorePersistsPDFDataRepresentation() throws {
        let store = makePayloadStore()
        let data = Data("%PDF-1.7 browser data representation".utf8)

        let copied = try store.savePDF(data: data, suggestedFilename: "Browser Report")

        XCTAssertEqual(copied.pathExtension, "pdf")
        XCTAssertEqual(copied.deletingPathExtension().lastPathComponent, "Browser Report")
        XCTAssertEqual(try Data(contentsOf: copied), data)
        store.deleteManagedPDF(at: copied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testSourceLinkStoreRejectsNonPDFDataRepresentation() throws {
        let store = makePayloadStore()

        XCTAssertThrowsError(try store.savePDF(data: Data("not a pdf".utf8)))
    }

    func testDeletingFailedLocalPDFHandoffRemovesManagedCopy() throws {
        let store = makePayloadStore()
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-failed-pdf-source-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(sourceDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("Failed Report.pdf")
        try Data("%PDF-1.7 test".utf8).write(to: source)
        let copied = try store.savePDF(from: source)
        let handoff = SourceLinkHandoff(
            id: "failed-local-pdf",
            inputURL: copied.absoluteString,
            sourceSurface: "share_sheet_pdf_file",
            startSession: false
        )
        try store.save(handoff)
        try store.quarantine(payloadID: handoff.id, reason: "Could not read PDF")

        try store.deleteFailed(payloadID: handoff.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(try store.failedHandoffs().isEmpty)
    }

    func testSourceLinkPayloadStoreQuarantinesAndRetriesFailure() throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "payload-source-link-failed",
            inputURL: "https://example.com/unresolved",
            sourceSurface: "share_sheet",
            startSession: false
        )
        try store.save(handoff)

        try store.quarantine(payloadID: handoff.id, reason: "No playable audio")

        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id))
        let failed = try XCTUnwrap(store.failedHandoffs().first)
        XCTAssertEqual(failed.handoff, handoff)
        XCTAssertEqual(failed.reason, "No playable audio")

        try store.retryFailed(payloadID: handoff.id)

        XCTAssertEqual(try store.handoff(payloadID: handoff.id), handoff)
        XCTAssertTrue(try store.failedHandoffs().isEmpty)
    }

    func testIncomingSourceLinkURLImportsAndStartsPlayableItem() {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Episode Audio",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()

        model.handleIncomingURL(SourceLinkHandoffURL.url(for: SourceLinkHandoff(
            id: "source-link-direct",
            inputURL: "https://example.com/episode",
            sourceSurface: "url",
            startSession: true
        )))

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(model.snapshot.targetId, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(model.selectedItem.externalReference, "https://example.com/episode")
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.snapshot.itemId })?.status, "Audio ready")
        XCTAssertEqual(model.diagnostics["lastSourceLinkStatus"], LinkResolutionStatus.playable.rawValue)

        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.seekToMediaTime) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.setPlaybackRate) == true)
        model.dispatchGate2CompactCommand(.seekToMediaTime, mediaTimeMs: 120_000, origin: "now_playing")
        model.dispatchGate2CompactCommand(.setPlaybackRate, playbackRate: 1.5, origin: "now_playing")

        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 120_000)
        XCTAssertEqual(model.snapshot.playbackRate, 1.5)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], CompactControlCommand.setPlaybackRate.rawValue)
        XCTAssertEqual(model.diagnostics["gate2LastResult"], "delegated")
        XCTAssertNil(model.lastError)
    }

    func testIncomingSourceLinkAddsToLibraryWithoutReplacingPlaybackFromLibraryRoot() throws {
        let sharedURL = "https://example.com/shared-during-playback"
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: sharedURL, provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: sharedURL, provider: "direct_audio", role: "audio_file"),
                title: "Shared During Playback",
                durationMs: 240_000,
                audioURL: "https://cdn.example.com/shared-during-playback.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let snapshotBeforeImport = model.snapshot
        model.openHome()

        model.handleIncomingURL(SourceLinkHandoffURL.url(for: SourceLinkHandoff(
            id: "source-link-during-playback",
            inputURL: sharedURL,
            sourceSurface: "share_sheet",
            startSession: true
        )))

        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.snapshot.sessionId, snapshotBeforeImport.sessionId)
        XCTAssertEqual(model.snapshot.itemId, snapshotBeforeImport.itemId)
        XCTAssertEqual(model.snapshot.targetId, snapshotBeforeImport.targetId)
        XCTAssertEqual(model.snapshot.currentTextStart, snapshotBeforeImport.currentTextStart)
        XCTAssertTrue(model.libraryItems.contains { $0.title == "Shared During Playback" })
        XCTAssertEqual(
            model.statusMessage,
            "Added Shared During Playback to Library without changing Now Playing."
        )
    }

    func testNativeAudioPlaybackRatePreferenceSurvivesSessionSnapshotsAndRemoteChanges() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "mediaPlaybackRate")
        defer {
            if let previous {
                defaults.set(previous, forKey: "mediaPlaybackRate")
            } else {
                defaults.removeObject(forKey: "mediaPlaybackRate")
            }
        }
        defaults.set(1.75, forKey: "mediaPlaybackRate")
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Remembered Rate Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/remembered-rate.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        XCTAssertEqual(model.snapshot.playbackRate, 1.75, accuracy: 0.001)
        XCTAssertEqual(model.mediaPlaybackRate, 1.75, accuracy: 0.001)

        model.setMediaPlaybackRate(0.33)
        XCTAssertEqual(model.mediaPlaybackRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(model.snapshot.playbackRate, 0.5, accuracy: 0.001)
        model.setMediaPlaybackRate(1.75)

        var olderSessionSnapshot = model.snapshot
        olderSessionSnapshot.playbackRate = 1
        model.snapshot = olderSessionSnapshot
        XCTAssertEqual(model.mediaPlaybackRate, 1.75, accuracy: 0.001)

        model.dispatchGate2CompactCommand(.setPlaybackRate, playbackRate: 1.5, origin: "now_playing")
        XCTAssertEqual(model.mediaPlaybackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(defaults.double(forKey: "mediaPlaybackRate"), 1.5, accuracy: 0.001)

        let relaunched = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        XCTAssertEqual(relaunched.mediaPlaybackRate, 1.5, accuracy: 0.001)
    }

    func testAmbiguousPodcastCandidatesRequireSelectionBeforeImport() throws {
        let originalURL = "https://open.spotify.com/episode/ambiguous"
        let first = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://podcasts.apple.com/one", provider: "apple_podcasts", role: "canonical_source"),
            title: "Shared title",
            showTitle: "Show One",
            durationMs: 120_000,
            publishedAt: "2026-07-01T00:00:00Z",
            audioURL: "https://cdn.example.com/one.mp3",
            confidence: 0.71
        )
        let second = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://podcasts.apple.com/two", provider: "apple_podcasts", role: "canonical_source"),
            title: "Shared title",
            showTitle: "Show Two",
            durationMs: 180_000,
            publishedAt: "2026-07-02T00:00:00Z",
            audioURL: "https://cdn.example.com/two.mp3",
            confidence: 0.70
        )
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .needsReview,
            originalLink: SourceLink(url: originalURL, provider: "spotify", role: "discovery"),
            candidates: [first, second],
            failureReason: "spotify_episode_match_ambiguous"
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        let itemCount = model.libraryItems.count

        XCTAssertFalse(model.importSourceLink(urlString: originalURL, sourceSurface: "paste"))
        XCTAssertEqual(model.libraryItems.count, itemCount)
        XCTAssertEqual(model.sourceLinkCandidateReview?.result.candidates, [first, second])

        model.selectSourceLinkCandidate(second)

        XCTAssertNil(model.sourceLinkCandidateReview)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetId, second.audioURL)
        XCTAssertEqual(model.selectedItem.externalReference, originalURL)
        XCTAssertEqual(model.selectedItem.title, "Shared title")
    }

    func testAmbiguousFormImportEntersReviewStateInsteadOfReportingFailure() async throws {
        let originalURL = "https://open.spotify.com/episode/ambiguous-form"
        let candidates = [
            LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://podcasts.apple.com/one", provider: "apple_podcasts", role: "canonical_source"),
                title: "First match",
                durationMs: 120_000,
                audioURL: "https://cdn.example.com/one.mp3",
                confidence: 0.71
            ),
            LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://podcasts.apple.com/two", provider: "apple_podcasts", role: "canonical_source"),
                title: "Second match",
                durationMs: 180_000,
                audioURL: "https://cdn.example.com/two.mp3",
                confidence: 0.70
            )
        ]
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .needsReview,
            originalLink: SourceLink(url: originalURL, provider: "spotify", role: "discovery"),
            candidates: candidates,
            failureReason: "spotify_episode_match_ambiguous"
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        model.sourceLinkURL = originalURL

        XCTAssertTrue(model.beginSourceLinkImportFromForm())
        try await waitFor("ambiguous form review") {
            model.sourceLinkImportState == "review"
        }

        XCTAssertEqual(model.sourceLinkCandidateReview?.result.candidates, candidates)
        XCTAssertEqual(model.sourceLinkImportMessage, "Choose the matching podcast episode.")
        XCTAssertNil(model.lastError)
    }

    #if canImport(UIKit)
    func testPDFImportPreservesActiveNativeMediaSession() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Episode Audio",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        model.setMediaPlaybackRate(1.5)
        model.seekMedia(toMediaTimeMs: 87_000)
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let itemId = try XCTUnwrap(model.snapshot.itemId)
        let targetId = try XCTUnwrap(model.snapshot.targetId)
        let selectedItemId = model.selectedItem.id

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-active-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Imported During Playback.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            ("PDF text imported without replacing playback." as NSString).draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }

        model.importObsidianMarkdownFiles(urls: [file])
        try await waitFor("PDF import to preserve native playback", timeoutNanoseconds: 5_000_000_000) {
            !model.isImportingSources
        }

        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertEqual(model.snapshot.itemId, itemId)
        XCTAssertEqual(model.snapshot.targetId, targetId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 87_000)
        XCTAssertEqual(model.snapshot.playbackRate, 1.5)
        XCTAssertEqual(model.selectedItem.id, selectedItemId)
        XCTAssertEqual(model.gate2CompactSnapshot?.sessionId, sessionId)
        XCTAssertNotNil(model.libraryItems.first(where: { $0.title == "Imported During Playback" }))
    }
    #endif

    func testRetryContextUsesRelocatedOwnedAudiobookAndReportsCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let db = root.appending(path: "library.sqlite")
        let transcriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "context", startMs: 0, endMs: 10_000, text: "Recovered local context")], chapters: [], durationMs: 60_000))
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), sourceTranscriptionClient: transcriber, databaseURLOverride: db)
        model.resetAndSeed()
        model.declineCurrentTerms()
        let store = try SQLiteSessionStore(path: db.path)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let relative = "Audiobooks/context-\(UUID().uuidString).caf"
        let local = support.appending(path: relative)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let item = Item(id: "context-local", title: "Local audiobook", mediaType: "audiobook", text: nil,
            externalReference: "file:///former-container/missing.caf", status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///former-container/missing.caf", durationMs: 60_000))
        try store.seed(item: item)
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: "owned-context", itemId: item.id, category: .audiobook,
            relativePath: relative, byteCount: 7, checksumSHA256: "fixture", isReproducible: false))
        model.openItem(id: item.id)
        model.startItem(id: item.id)
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        let note = Interjection(id: "retry-context", itemId: item.id, sessionId: sessionID, targetType: .item,
            targetId: item.id, createdAt: Date(), roughPercent: 8,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 5_000),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "My note",
            cleanedTranscript: nil, displayText: nil, status: "active", anchorContextStatus: .unavailable)
        try store.saveInterjection(note)
        model.retryAnchorContext(note)
        XCTAssertTrue(model.isRetryingAnchorContext(note))
        let request = await transcriber.waitForWindowRequest()
        XCTAssertEqual(request.url.standardizedFileURL, local.standardizedFileURL)
        try await waitFor("manual context recovery") { !model.isRetryingAnchorContext(note) }
        XCTAssertEqual(try store.loadInterjections(sessionId: sessionID).first?.anchorContextStatus, .ready)
        XCTAssertEqual(model.feedbackEvent?.message, "Source context recovered.")
    }

    /// #871 / #1308 (ANC-03): when a download finishes, every saved Margin on the episode wants its source context. The
    /// app must send those jobs through its SourceWindowJobQueue, two at a time, skip a Margin deleted while it waited,
    /// and clear every pending mark. The queue's own tests can't see the call site: replacing the enqueue with a bare
    /// Task, the original burst, passed them all.
    func testADownloadRecoversEachMarginsContextTwoAtATimeAndSkipsADeletedOne() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Many Margins Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/many-margins.mp3",
                confidence: 1
            )
        ))
        let root = FileManager.default.temporaryDirectory.appending(path: "context-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let db = root.appending(path: "library.sqlite")
        let transcriber = GatedSourceWindowTranscriptionClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            localFoundationModelClient: SourceLinkFoundationModelStub(),
            databaseURLOverride: db
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        let itemId = try XCTUnwrap(model.snapshot.itemId)
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let store = try SQLiteSessionStore(path: db.path)
        let margins = (1...6).map { index in
            Interjection(id: "queued-\(index)", itemId: itemId, sessionId: sessionId, targetType: .item,
                targetId: itemId, createdAt: Date(), roughPercent: index * 7,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "",
                               mediaTimeMs: index * 20_000),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "Note \(index)",
                cleanedTranscript: nil, displayText: nil, status: "active", anchorContextStatus: .unavailable)
        }
        for margin in margins { try store.saveInterjection(margin) }

        let localURL = root.appending(path: "many-margins.mp3")
        try Data("downloaded".utf8).write(to: localURL)
        model.podcastLocalAssetDidBecomeReady(itemId: itemId, url: localURL)
        for margin in margins {
            XCTAssertTrue(model.isRetryingAnchorContext(margin), "\(margin.id) is waiting for its context")
        }

        try await waitFor("two jobs to start", timeoutNanoseconds: 5_000_000_000) { transcriber.runningNow == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transcriber.runningNow, 2, "the other four wait for a slot")

        // A Margin the listener deletes while its job waits is kept with status "deleted"; its job must not run.
        let started = Set(transcriber.startedAnchors)
        var deleted = try XCTUnwrap(margins.first { !started.contains($0.anchor.mediaTimeMs ?? 0) })
        deleted.status = "deleted"
        try store.saveInterjection(deleted)

        try await waitFor("every job to finish and clear its pending mark", timeoutNanoseconds: 10_000_000_000) {
            transcriber.releaseWaiting()
            return margins.allSatisfy { !model.isRetryingAnchorContext($0) }
        }
        XCTAssertEqual(transcriber.peakRunning, 2, "at most two source-window jobs at once")
        XCTAssertEqual(transcriber.startedAnchors.count, 5, "one job per Margin, none for the deleted one")
        XCTAssertFalse(transcriber.startedAnchors.contains(deleted.anchor.mediaTimeMs ?? 0), "the deleted Margin's job ran")
    }

    func testStreamedMarginContextComesFromTheAudioHeardAroundIt() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Windowed Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/windowed.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        // Timed from the start of the heard file, as the real transcriber reports it.
        let transcriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "window-before", startMs: 0, endMs: 59_000, text: "Minute before."),
                MediaTimelineSegment(id: "window-current", startMs: 59_000, endMs: 61_000, text: "Interjection context."),
                MediaTimelineSegment(id: "window-after", startMs: 61_000, endMs: 120_000, text: "Minute after.")
            ],
            chapters: [],
            durationMs: 120_000
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: transcriber,
            interjectionTranscriptionHandler: { _ in "Recorded note." }
        )
        let heardRoot = try makeHeardWindowRoot(for: model)
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        // #156: a stream can't be cut after the fact, so nothing is sent to the transcriber until the heard audio arrives.
        try await waitFor("the Margin to wait for heard audio") {
            model.marginDiagnostic("sourceWindowTranscription", interjectionId: "ij-001") == "waiting:heard_audio"
        }
        let beforeHeard = await transcriber.windowRequestCount()
        XCTAssertEqual(beforeHeard, 0)

        try await deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)
        let request = await transcriber.waitForWindowRequest()
        try await waitFor("source window context to attach") {
            model.marginDiagnostic("sourceWindowTranscription", interjectionId: "ij-001") == "complete:heard_audio:3_segments"
        }

        XCTAssertTrue(request.url.isFileURL, "the heard audio is transcribed from a local file, not the stream")
        XCTAssertEqual(request.anchorMediaTimeMs, 0)
        XCTAssertEqual(request.windowBeforeMs, 0)
        XCTAssertEqual(request.windowAfterMs, 120_000)
        XCTAssertEqual(request.durationMs, 120_000)
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorBefore, "Minute before. Interjection context.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorAfter, "Minute after.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchorContextStatus, .ready)
        XCTAssertEqual(model.marginDiagnostic("sourceWindowContextProvenance", interjectionId: "ij-001"), "heard_stream_audio")
        try await waitFor("the used heard audio to be deleted") {
            (try? FileManager.default.contentsOfDirectory(atPath: heardRoot.path))?.isEmpty == true
        }
    }

    /// #652: heard audio for a Margin whose context is already ready is never used, so it mustn't stay in the cache,
    /// and the Margin's context must stay as it was.
    func testHeardAudioForAMarginWithReadyContextIsDiscarded() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Ready Context Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/ready.mp3",
                confidence: 1
            )
        ))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let db = root.appending(path: "library.sqlite")
        let audio = WindowContextAudioClient()
        let transcriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "heard", startMs: 0, endMs: 120_000, text: "Heard context.")],
            chapters: [], durationMs: 120_000
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: transcriber,
            interjectionTranscriptionHandler: { _ in "Recorded note." },
            databaseURLOverride: db
        )
        let heardRoot = try makeHeardWindowRoot(for: model)
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("the Margin to wait for heard audio") {
            model.marginDiagnostic("sourceWindowTranscription", interjectionId: "ij-001") == "waiting:heard_audio"
        }
        // The context arrives another way (a publisher transcript, say) before the heard audio is handed over.
        let store = try SQLiteSessionStore(path: db.path)
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        var margin = try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first { $0.id == "ij-001" })
        margin.anchor.anchorBefore = "Context already known."
        margin.anchor.anchorAfter = "And after it."
        margin.anchorContextStatus = .ready
        try store.saveInterjection(margin)

        try await deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)

        // The unused files are removed off the main thread (#2510), so they go a moment after the hand-over.
        try await waitFor("the unused heard audio to be deleted") {
            (try? FileManager.default.contentsOfDirectory(atPath: heardRoot.path))?.isEmpty == true
        }
        XCTAssertNil(model.heardSourceWindows.segments(for: "\(sessionId)::ij-001"))
        let requests = await transcriber.windowRequestCount()
        XCTAssertEqual(requests, 0)
        let saved = try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first { $0.id == "ij-001" })
        XCTAssertEqual(saved.anchorContextStatus, .ready)
        XCTAssertEqual(saved.anchor.anchorBefore, "Context already known.")
        XCTAssertEqual(saved.anchor.anchorAfter, "And after it.")
    }

    func testInterjectionTranscriptionFinishesBeforeSourceWindowTranscriptionStarts() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Serialized Transcription Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/serialized.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let sourceTranscriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "context", startMs: 120_000, endMs: 125_000, text: "Source context.")],
            chapters: [],
            durationMs: 300_000
        ))
        let interjectionTranscriber = ControlledInterjectionTranscriber()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: sourceTranscriber,
            interjectionTranscriptionHandler: { audioPath in
                try await interjectionTranscriber.transcribe(audioPath: audioPath)
            }
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        await interjectionTranscriber.waitForRequest()
        try await deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)

        let sourceRequestsBeforeNoteFinished = await sourceTranscriber.windowRequestCount()
        XCTAssertEqual(sourceRequestsBeforeNoteFinished, 0)

        await interjectionTranscriber.complete(with: "My recorded note.")
        _ = await sourceTranscriber.waitForWindowRequest()
        try await waitFor("both transcription stages to finish") {
            model.marginDiagnostic("sourceWindowTranscription", interjectionId: "ij-001")?.hasPrefix("complete:heard_audio") == true
        }

        XCTAssertEqual(model.marginDiagnostic("interjectionTranscription", interjectionId: "ij-001"), "complete")
        XCTAssertEqual(
            model.marginDiagnostic("interjectionAnchorAtCapture", interjectionId: "ij-001"),
            "type=media;media_time=present;segment=missing;before=missing;after=missing;context=pending"
        )
        XCTAssertEqual(model.selectedItem.interjections.first?.transcript, "My recorded note.")
    }

    func testCompletedPodcastDownloadDoesNotTranscribeFullSourceWithoutListeningMapRequest() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "rss", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", role: "canonical_feed"),
                title: "Battery-Safe Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/battery-safe.mp3",
                confidence: 1
            )
        ))
        let transcriber = RecordingFullSourceTranscriptionClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            localFoundationModelClient: SourceLinkFoundationModelStub()
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        let itemId = try XCTUnwrap(model.snapshot.itemId)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("battery-safe.mp3")
        model.podcastLocalAssetDidBecomeReady(itemId: itemId, url: localURL)
        await Task.yield()

        let fullRequestCount = await transcriber.fullRequestCount()
        XCTAssertEqual(fullRequestCount, 0)
        XCTAssertEqual(
            model.diagnostics["sourceTranscriptionAfterDownload:\(itemId)"],
            "not_requested"
        )
    }

    func testExplicitPodcastRedownloadCanReplacePausedTransportWhileAutomaticCompletionCannot() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "rss", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", role: "canonical_feed"),
                title: "Battery-Safe Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/battery-safe.mp3",
                confidence: 1
            )
        ))
        let transcriber = RecordingFullSourceTranscriptionClient()
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            sourceTranscriptionClient: transcriber,
            localFoundationModelClient: SourceLinkFoundationModelStub()
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        let itemId = try XCTUnwrap(model.snapshot.itemId)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("battery-safe.mp3")
        model.podcastLocalAssetDidBecomeReady(itemId: itemId, url: localURL)
        model.pause()
        model.resumePlayback()
        XCTAssertNil(audio.lastMediaContext?.playbackURL, "Automatic completion changed the active edition")
        model.pause()
        model.redownloadSelectedPodcast()
        let replacement = localURL.deletingLastPathComponent().appendingPathComponent("replacement.mp3")
        model.podcastLocalAssetDidBecomeReady(itemId: itemId, url: replacement)
        XCTAssertEqual(audio.lastMediaContext?.playbackURL, replacement.absoluteString)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.resumePlayback()
        XCTAssertEqual(audio.lastMediaContext?.playbackURL, replacement.absoluteString)
    }

    func testPrivateEpisodeMapRequiresExplicitRequestBeforeDownloadTranscription() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "rss", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", role: "canonical_feed"),
                title: "Mapped Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/mapped.mp3",
                confidence: 1
            )
        ))
        let transcriber = RecordingFullSourceTranscriptionClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            localFoundationModelClient: SourceLinkFoundationModelStub()
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        let itemId = try XCTUnwrap(model.snapshot.itemId)
        XCTAssertTrue(model.canGenerateListeningMap)
        let requestsBeforeConsent = await transcriber.fullRequestCount()
        XCTAssertEqual(requestsBeforeConsent, 0)
        model.generateListeningMap()
        XCTAssertNil(model.lastError)

        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("mapped.mp3")
        model.podcastLocalAssetDidBecomeReady(itemId: itemId, url: localURL)
        await Task.yield()

        let fullRequestCount = await transcriber.fullRequestCount()
        XCTAssertEqual(fullRequestCount, 0)
        XCTAssertEqual(
            model.diagnostics["sourceTranscriptionAfterDownload:\(itemId)"],
            "requested_private_episode_map"
        )
    }

    func testSavedInterjectionAudioCanReplaceATruncatedTranscript() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Recoverable Interjection",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/recoverable.mp3",
                confidence: 1
            )
        ))
        // Each transcription waits here until the test settles it, so "a retry is pending" is observed, not assumed.
        let transcriber = GatedInterjectionTranscriber()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: WindowContextAudioClient(),
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient(),
            interjectionTranscriptionHandler: { audioPath in
                try await transcriber.transcribe(audioPath: audioPath)
            }
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        let firstRequested = await transcriber.waitUntilRequested(1)
        XCTAssertTrue(firstRequested, "the first transcription never started")
        await transcriber.settleNext(.success("Only the ending survived."))
        try await waitFor("initial transcript") {
            model.selectedItem.interjections.first?.transcript == "Only the ending survived."
        }
        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)
        // The same note ID in another session: Margin IDs repeat per session, so only the stored identity tells them apart.
        var sameIdElsewhere = interjection
        sameIdElsewhere.sessionId = "another-session"
        let identity = Gate1AppModel.marginIdentity(interjection)
        XCTAssertNotEqual(identity, Gate1AppModel.marginIdentity(sameIdElsewhere))

        // A retry that succeeds: pending while the transcriber is suspended, gone once it completes.
        XCTAssertFalse(model.isRetryingInterjectionTranscription(interjection))
        model.retryInterjectionTranscription(interjection)
        XCTAssertTrue(model.isRetryingInterjectionTranscription(interjection), "the retry must be pending while the transcriber is suspended")
        XCTAssertFalse(model.isRetryingInterjectionTranscription(sameIdElsewhere), "another session's note with the same ID is not retrying")
        XCTAssertEqual(model.retryingInterjectionTranscriptionIds, [identity], "the set stores sessionId::id, never the bare ID")
        let secondRequested = await transcriber.waitUntilRequested(2)
        XCTAssertTrue(secondRequested, "the retry never reached the transcriber")
        await transcriber.settleNext(.success("The complete saved interjection is restored from its original audio."))
        try await waitFor("replacement transcript") {
            model.selectedItem.interjections.first?.transcript == "The complete saved interjection is restored from its original audio."
        }

        XCTAssertFalse(model.isRetryingInterjectionTranscription(interjection))
        XCTAssertTrue(model.retryingInterjectionTranscriptionIds.isEmpty, "a finished retry leaves no stored identity behind")
        XCTAssertEqual(model.diagnostics[Gate1AppModel.marginDiagnosticKey("interjectionTranscription", interjection)], "complete")

        // A retry that fails: pending the same way, then gone, with the words it already had kept.
        let recovered = try XCTUnwrap(model.selectedItem.interjections.first)
        model.retryInterjectionTranscription(recovered)
        XCTAssertTrue(model.isRetryingInterjectionTranscription(recovered))
        XCTAssertFalse(model.isRetryingInterjectionTranscription(sameIdElsewhere))
        XCTAssertEqual(model.retryingInterjectionTranscriptionIds, [identity])
        let thirdRequested = await transcriber.waitUntilRequested(3)
        XCTAssertTrue(thirdRequested, "the second retry never reached the transcriber")
        await transcriber.settleNext(.failure(SessionKitError.persistenceFailed("scripted_failure")))
        try await waitFor("failed retry evidence") {
            model.diagnostics[Gate1AppModel.marginDiagnosticKey("interjectionTranscription", interjection)]?.hasPrefix("retry_failed:") == true
        }

        XCTAssertEqual(model.selectedItem.interjections.first?.transcript, "The complete saved interjection is restored from its original audio.")
        XCTAssertEqual(model.selectedItem.interjections.first?.displayText, "The complete saved interjection is restored from its original audio.")
        XCTAssertFalse(model.isRetryingInterjectionTranscription(interjection))
        XCTAssertTrue(model.retryingInterjectionTranscriptionIds.isEmpty, "a failed retry leaves no stored identity behind")

        // #430: the failure names its Margin's listen and offers Retry. Retrying from the Margin withdraws that
        // offer, so the "Retranscribing" confirmation isn't held back behind a stale Retry.
        let failure = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(failure.origin, FeedbackOrigin(itemId: interjection.itemId, sessionId: interjection.sessionId, work: .marginTranscription))
        XCTAssertEqual(failure.retry?.key, Gate1AppModel.transcriptionRetryKey(interjection))
        XCTAssertNotEqual(Gate1AppModel.transcriptionRetryKey(interjection), Gate1AppModel.transcriptionRetryKey(sameIdElsewhere))
        model.retryInterjectionTranscription(try XCTUnwrap(model.selectedItem.interjections.first))
        XCTAssertEqual(model.feedbackEvent?.kind, .success)
        XCTAssertEqual(model.feedbackEvent?.message, "Retranscribing the saved Margin audio.")
        let fourthRequested = await transcriber.waitUntilRequested(4)
        XCTAssertTrue(fourthRequested, "the third retry never reached the transcriber")
        await transcriber.settleNext(.success("The complete saved interjection is restored from its original audio."))
        try await waitFor("third retry settles") { !model.isRetryingInterjectionTranscription(interjection) }
        XCTAssertNil(model.feedbackEvent?.retry, "a transcribed Margin leaves no Retry offer behind")
    }

    /// A Margin whose first transcription failed, with the Retry the failure offered captured as the banner holds it.
    private func modelWithAFailedMarginTranscription() async throws -> (model: Gate1AppModel, margin: Interjection, staleRetry: @MainActor () -> Void) {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Deleted Margin Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/deleted-margin.mp3",
                confidence: 1
            )
        ))
        let transcriber = GatedInterjectionTranscriber()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: WindowContextAudioClient(),
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient(),
            interjectionTranscriptionHandler: { audioPath in
                try await transcriber.transcribe(audioPath: audioPath)
            }
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        let requested = await transcriber.waitUntilRequested(1)
        XCTAssertTrue(requested, "the first transcription never started")
        await transcriber.settleNext(.failure(SessionKitError.persistenceFailed("scripted_failure")))
        try await waitFor("failed transcription offers Retry") { model.feedbackEvent?.retry != nil }
        let failure = try XCTUnwrap(model.feedbackEvent)
        let margin = try XCTUnwrap(model.selectedItem.interjections.first)
        XCTAssertEqual(failure.retry?.key, Gate1AppModel.transcriptionRetryKey(margin))
        return (model, margin, try XCTUnwrap(failure.retry).action)
    }

    /// #430, audit on 29cb964: a deleted Margin must not keep a working Retry.
    func testDeletingAMarginWhoseTranscriptionFailedWithdrawsItsRetryAndShowsTheConfirmation() async throws {
        let (model, margin, staleRetry) = try await modelWithAFailedMarginTranscription()

        model.deleteInterjection(margin)

        // The failure banner gives way to the delete's own Undo banner (#1981); its Retry must not survive.
        XCTAssertEqual(model.feedbackEvent?.kind, .success, "the deleted Margin's failure must go with it")
        XCTAssertNil(model.feedbackEvent?.retry, "the deleted Margin's Retry must go with it")
        XCTAssertEqual(model.feedbackEvent?.action?.identifier, "margin.deleteUndo.button")
        XCTAssertEqual(model.statusMessage, "Deleted Margin.")

        // A Retry captured before the delete (an old banner, an accessibility action) reads the Margin as stored now.
        staleRetry()
        XCTAssertTrue(model.retryingInterjectionTranscriptionIds.isEmpty, "a deleted Margin must not be transcribed again")
        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertEqual(model.feedbackEvent?.message, "That Margin was deleted, so there is nothing to retranscribe.")
        XCTAssertNil(model.feedbackEvent?.retry)
    }

    /// The same class: the item holding the Margin goes to Recently Deleted while its failure is up.
    func testMovingAnItemToRecentlyDeletedWithdrawsItsMarginRetry() async throws {
        let (model, margin, staleRetry) = try await modelWithAFailedMarginTranscription()

        model.moveItemToTrash(id: margin.itemId)

        XCTAssertNil(model.feedbackEvent, "a trashed item's Margin keeps no failure or Retry")
        XCTAssertTrue(model.statusMessage.hasPrefix("Moved "), model.statusMessage)

        staleRetry()
        XCTAssertTrue(model.retryingInterjectionTranscriptionIds.isEmpty, "a Margin in Recently Deleted must not be transcribed again")
        XCTAssertEqual(model.feedbackEvent?.message, "That Margin was deleted, so there is nothing to retranscribe.")
    }

    func testUnavailablePodcastContextKeepsTimestampAndPersistedRetryState() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Offline Context Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/offline-context.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient(),
            interjectionTranscriptionHandler: { _ in "Recorded note." }
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)
        try await waitFor("source window failure to persist") {
            model.selectedItem.interjections.first?.anchorContextStatus == .unavailable
        }

        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)
        XCTAssertEqual(interjection.anchor.mediaTimeMs, 123_000)
        XCTAssertEqual(interjection.anchorContextStatus, .unavailable)
        XCTAssertEqual(interjection.anchor.anchorBefore, "")
        XCTAssertEqual(interjection.anchor.anchorAfter, "")
        XCTAssertNil(model.lastError)
        XCTAssertNotEqual(model.feedbackEvent?.kind, .error)
    }

    func testOlderPodcastSessionKeepsExactPositionAfterOpeningAndClosingNewSession() throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/resume-episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/resume-episode", provider: "direct_audio", role: "audio_file"),
                title: "Exact Session Resume Episode",
                durationMs: 3_600_000,
                audioURL: "https://cdn.example.com/resume-episode.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/resume-episode", sourceSurface: "paste"))
        let itemID = try XCTUnwrap(model.snapshot.itemId)
        let olderSessionID = try XCTUnwrap(model.snapshot.sessionId)

        audio.currentMediaTimeValue = 2_100_000
        model.pause()
        model.startNewSession(id: itemID)
        let newerSessionID = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(newerSessionID, olderSessionID)
        model.endSession()

        let olderSession = try XCTUnwrap(
            model.selectedItem.sessions.first(where: { $0.id == olderSessionID })
        )
        model.openSession(olderSession)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 2_100_000)
        model.resumeSession(olderSession)

        XCTAssertEqual(model.snapshot.sessionId, olderSessionID)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 2_100_000)
        XCTAssertEqual(audio.currentMediaTimeValue, 2_100_000)
    }

    func testConfiguredNativeAudioSkipIntervalsAreAppliedAndPersisted() {
        defer {
            UserDefaults.standard.removeObject(forKey: "mediaSkipBackSeconds")
            UserDefaults.standard.removeObject(forKey: "mediaSkipForwardSeconds")
        }
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Configurable Skip Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/configurable-skip.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        model.mediaSkipBackSeconds = 30
        model.mediaSkipForwardSeconds = 45
        model.mediaSkipSettingsChanged()

        audio.currentMediaTimeValue = 60_000
        model.skipForwardMedia()
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 105_000)
        audio.currentMediaTimeValue = 105_000
        model.skipBackMedia()
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 75_000)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "mediaSkipBackSeconds"), 30)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "mediaSkipForwardSeconds"), 45)
    }

    func testClipboardButtonExtractsSourceLinkURL() throws {
        #if canImport(UIKit)
        UIPasteboard.general.string = "Listen here: https://podcasts.apple.com/us/podcast/show/id123456?i=999"
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())

        model.pasteSourceLinkFromClipboard()

        XCTAssertEqual(model.sourceLinkURL, "https://podcasts.apple.com/us/podcast/show/id123456?i=999")
        XCTAssertEqual(model.statusMessage, "Pasted link from Clipboard.")
        #else
        throw XCTSkip("Clipboard is only available with UIKit")
        #endif
    }

    func testTextClipboardButtonFillsManualImportField() throws {
        #if canImport(UIKit)
        UIPasteboard.general.string = "A fresh passage to import."
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())

        model.pasteImportTextFromClipboard()

        XCTAssertEqual(model.importText, "A fresh passage to import.")
        XCTAssertEqual(model.statusMessage, "Pasted text from Clipboard.")
        #else
        throw XCTSkip("Clipboard is only available with UIKit")
        #endif
    }

    func testAsyncSourceLinkFormClearsLinkAfterSuccessfulProcessing() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "audio_file"),
                title: "Form Episode",
                audioURL: "https://cdn.example.com/form-episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        model.sourceLinkURL = "https://example.com/form-episode"

        model.beginSourceLinkImportFromForm()
        try await waitFor("source link field to clear") {
            model.sourceLinkURL.isEmpty
        }

        XCTAssertEqual(model.selectedItem.title, "Form Episode")
    }

    func testSourceLinkFormRejectsMalformedURLWithoutClearingAndDeduplicatesActiveResolution() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "audio_file"),
                title: "Form Episode",
                audioURL: "https://cdn.example.com/form-episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        model.sourceLinkURL = "not a URL"

        XCTAssertFalse(model.beginSourceLinkImportFromForm())
        XCTAssertEqual(model.sourceLinkURL, "not a URL")
        XCTAssertEqual(model.sourceLinkImportState, "failure")

        model.sourceLinkURL = "https://example.com/form-episode"
        XCTAssertTrue(model.beginSourceLinkImportFromForm())
        XCTAssertFalse(model.beginSourceLinkImportFromForm())
        try await waitFor("source resolution to finish") { model.sourceLinkImportState == "success" }
        XCTAssertEqual(model.selectedItem.title, "Form Episode")
    }

    func testIncomingPayloadIsQuarantinedAfterUnsupportedImport() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "source-link-unsupported",
            inputURL: "https://open.spotify.com/episode/abc123",
            sourceSurface: "share_sheet",
            startSession: true
        )
        try store.save(handoff)
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .unsupported,
            originalLink: SourceLink(url: handoff.inputURL, provider: "spotify", role: "discovery"),
            selectedCandidate: nil,
            failureReason: "spotify_audio_requires_provider_playback"
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        model.handleIncomingURL(SourceLinkHandoffURL.url(forPayloadID: handoff.id))
        // The drain sets its busy flag back last, after the quarantine file, the diagnostics and the inbox refresh (#2510).
        try await waitFor("unsupported share quarantine") {
            (try? store.failedHandoffs().count) == 1 && !model.isImportingPendingSourceLinkHandoffs
        }

        XCTAssertEqual(model.diagnostics["lastSourceLinkPayloadCleanup"], "queued:\(handoff.id)")
        XCTAssertTrue(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"]?.hasPrefix("quarantined:") == true)
        XCTAssertEqual(model.diagnostics["lastSourceLinkFailureCategory"], "spotify_audio_requires_provider_playback")
        XCTAssertNil(model.lastError)
        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id))
        let failed = try XCTUnwrap(store.failedHandoffs().first)
        XCTAssertEqual(failed.handoff, handoff)
        XCTAssertTrue(
            failed.reason.contains("could not find a public audio file"),
            "Unexpected quarantine reason: \(failed.reason)"
        )
        XCTAssertFalse(failed.reason.contains("persistence_failed"), "Unexpected quarantine reason: \(failed.reason)")
        XCTAssertFalse(failed.reason.contains("open.spotify.com"))
        XCTAssertEqual(model.importInbox.first?.payloadID, handoff.id)
    }

    func testForegroundActivationImportsSavedShareWithoutReplacingPlayback() async throws {
        let store = makePayloadStore()
        let sharedHandoff = SourceLinkHandoff(
            id: "source-link-shared",
            inputURL: "https://example.com/shared-episode",
            sourceSurface: "share_sheet",
            startSession: false
        )
        try store.save(sharedHandoff)
        let resolver = CountingAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: sharedHandoff.inputURL, provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: sharedHandoff.inputURL, provider: "direct_audio", role: "audio_file"),
                title: "Shared Episode",
                audioURL: "https://cdn.example.com/shared.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let snapshotBeforeImport = model.snapshot

        model.handleAppBecameActive()
        // The event this test needs is the drain finishing: the episode is in the Library and the saved share's file
        // is gone. The file is deleted off the main thread, so waiting on the title alone let the assertion below
        // race that delete once on the hosted run (#2630: the read failed with a file error, not "missing").
        try await waitFor("shared episode import") {
            model.libraryItems.contains { $0.title == "Shared Episode" }
                && !model.isImportingPendingSourceLinkHandoffs
                && ((try? store.pendingPayloadIDs()) ?? ["unreadable"]).isEmpty
        }

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.sessionId, snapshotBeforeImport.sessionId)
        XCTAssertEqual(model.snapshot.itemId, snapshotBeforeImport.itemId)
        XCTAssertEqual(model.snapshot.targetId, snapshotBeforeImport.targetId)
        XCTAssertEqual(model.snapshot.status, snapshotBeforeImport.status)
        XCTAssertEqual(model.snapshot.phase, snapshotBeforeImport.phase)
        XCTAssertEqual(model.snapshot.currentTextStart, snapshotBeforeImport.currentTextStart)
        XCTAssertNotEqual(model.selectedItem.title, "Shared Episode")
        XCTAssertTrue(model.libraryItems.contains { $0.title == "Shared Episode" })
        XCTAssertEqual(resolver.resolveCount, 1)
        XCTAssertThrowsError(try store.handoff(payloadID: sharedHandoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(sharedHandoff.id))
        }
    }

    func testBackgroundPodcastTranscriptCompletionDoesNotSpliceItIntoActivePlayback() async throws {
        let store = makePayloadStore()
        let sharedHandoff = SourceLinkHandoff(
            id: "source-link-transcript-race",
            inputURL: "https://example.com/transcript-race",
            sourceSurface: "share_sheet",
            startSession: false
        )
        try store.save(sharedHandoff)
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: sharedHandoff.inputURL, provider: "rss", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/feed", provider: "rss", role: "canonical_feed"),
                title: "Transcript Race Podcast",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/transcript-race.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let activeTitle = model.selectedItem.title
        let activeSessionID = model.snapshot.sessionId

        model.handleAppBecameActive()
        try await waitFor("background podcast import") {
            model.libraryItems.contains { $0.title == "Transcript Race Podcast" } && !model.isImportingPendingSourceLinkHandoffs
        }
        let podcastID = try XCTUnwrap(
            model.libraryItems.first(where: { $0.title == "Transcript Race Podcast" })?.id
        )

        model.attachSourceTranscriptTimeline(
            TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "segment-1", startMs: 0, endMs: 2_000, text: "Podcast transcript")],
                chapters: [],
                durationMs: 300_000
            ),
            itemId: podcastID
        )

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.itemId, activeItemID)
        XCTAssertEqual(model.snapshot.sessionId, activeSessionID)
        XCTAssertEqual(model.selectedItem.id, activeItemID)
        XCTAssertEqual(model.selectedItem.title, activeTitle)
        XCTAssertTrue(model.selectedItem.interjections.allSatisfy { $0.itemId == activeItemID })
    }

    func testPendingSourceLinkHandoffImportsAndDeletesOnSuccess() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "source-link-pending",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            startSession: true
        )
        try store.save(handoff)
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: handoff.inputURL, provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: handoff.inputURL, provider: "direct_audio", role: "audio_file"),
                title: "Pending Episode",
                audioURL: "https://cdn.example.com/pending.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        model.importPendingSourceLinkHandoffs()
        try await waitFor("pending episode import") {
            model.libraryItems.contains { $0.title == "Pending Episode" } && !model.isImportingPendingSourceLinkHandoffs
        }

        XCTAssertEqual(model.screen, .home)
        XCTAssertNotEqual(model.selectedItem.title, "Pending Episode")
        XCTAssertEqual(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"], "imported")
        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(handoff.id))
        }
    }

    func testAppleProviderDoesNotUseSpotifyExclusiveFailureCopy() {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .needsReview,
            originalLink: SourceLink(url: "https://podcasts.apple.com/us/podcast/show/id123456?i=999", provider: "apple_podcasts", role: "discovery"),
            selectedCandidate: nil,
            failureReason: "spotify_audio_requires_provider_playback"
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        model.importSourceLink(
            urlString: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste"
        )

        XCTAssertEqual(model.diagnostics["lastSourceLinkProvider"], "apple_podcasts")
        XCTAssertEqual(
            model.lastError,
            "This provider did not expose a public audio file that Spoken Margins can play yet."
        )
    }

    private func makePayloadStore() -> SourceLinkHandoffStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-source-link-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return SourceLinkHandoffStore(baseDirectory: directory)
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let interval: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail("Timed out waiting for \(description).")
    }
}

// MARK: Recovering a private-feed packet's episode from the listener's own feed (#454)

extension SourceLinkImportTests {
    private static let episode12Audio = "https://media.members.example/ep12.mp3"
    private static let episode13Audio = "https://media.members.example/ep13.mp3"
    private static let pastedSecret = "PASTEDsecret0123456789"
    private static let pastedFeedLink = "https://members.example/feed.rss?auth=PASTEDsecret0123456789"

    private struct PrivateFeedFixture {
        let model: Gate1AppModel
        let store: SQLiteSessionStore
        let packageURL: URL
        let manifest: SpokenMarginsPackageManifest
    }

    /// A recipient whose Library lacks the episode, with a packet from a private feed open for import:
    /// podcast, recipient-supplied, no link and no GUID.
    private func makePrivateFeedFixture(
        showTitle: String? = "Members Only Show", publishedAt: String? = "2026-09-01T00:00:00Z"
    ) async throws -> PrivateFeedFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Model background tasks retain SQLite beyond this test; do not unlink its open WAL.
        let databaseURL = root.appending(path: "library.sqlite")
        let packageURL = root.appending(path: "private.spokenmargins")
        let created = Date(timeIntervalSince1970: 1_777_000_000)
        let revision = InterjectionShareRevision(
            id: "revision", interjectionId: "margin", itemId: "sender", sessionId: "sender-session", createdAt: created,
            approvedTranscript: "A thought on the private episode.", anchorBefore: "", anchorAfter: "", status: .senderApproved)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "private-feed-package",
            createdAt: created,
            item: SharedItemIdentity(
                itemType: .podcast,
                title: "Episode 12: The Private One",
                showTitle: showTitle,
                publishedAt: publishedAt,
                durationMs: 3_780_000
            ),
            itemTransportSelection: .recipientSupplied,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-001", revision: revision,
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 600_000), representation: .textOnly)],
            senderDisplayLabel: "Ana"
        )
        let manifest = try SpokenMarginsPackageArchive.write(prepared, to: packageURL)
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: EchoAudioLinkResolver(), audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        await model.waitForPackageStaging()
        return PrivateFeedFixture(model: model, store: store, packageURL: packageURL, manifest: manifest)
    }

    private func parsedFeed(_ episodes: [(title: String, guid: String, published: String, minutes: Int, audio: String)], show: String = "Members Only Show") throws -> ParsedFeed {
        var items = ""
        for episode in episodes {
            items += "<item><title>\(episode.title)</title><link>https://members.example/episodes/\(episode.guid)</link>"
            items += "<guid isPermaLink=\"false\">\(episode.guid)</guid><pubDate>\(episode.published)</pubDate>"
            items += "<itunes:duration>\(episode.minutes * 60)</itunes:duration>"
            items += "<enclosure url=\"\(episode.audio)\" type=\"audio/mpeg\"/></item>"
        }
        return try FeedParser().parse(data: Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>\(show)</title>\(items)</channel></rss>
        """.utf8))
    }

    /// The listener's feed: the newest episode first, as feeds list them.
    private func membersFeed(includingEpisode12: Bool = true, show: String = "Members Only Show") throws -> ParsedFeed {
        var episodes = [(title: "Episode 13: The Next One", guid: "ep-13", published: "Tue, 08 Sep 2026 00:00:00 +0000", minutes: 50, audio: Self.episode13Audio)]
        if includingEpisode12 {
            episodes.append((title: "Episode 12: The Private One", guid: "ep-12", published: "Tue, 01 Sep 2026 00:00:00 +0000", minutes: 63, audio: Self.episode12Audio))
        }
        episodes.append((title: "Episode 11: The Earlier One", guid: "ep-11", published: "Tue, 25 Aug 2026 00:00:00 +0000", minutes: 58, audio: "https://media.members.example/ep11.mp3"))
        return try parsedFeed(episodes, show: show)
    }

    private func recovery(for model: Gate1AppModel, feed: ParsedFeed) -> SharedEpisodeRecovery {
        var services = SharedEpisodeRecovery.services(model: model)
        services.fetchFeed = { _ in feed }
        return SharedEpisodeRecovery(services: services)
    }

    func testPastedFeedWithOneMatchingEpisodeAddsThatEpisodeAndThePendingImportBecomesImportable() async throws {
        let fixture = try await makePrivateFeedFixture()
        let model = fixture.model
        XCTAssertTrue(SharedEpisodeFeedMatcher.isPrivatePodcastSource(fixture.manifest))
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.requiresRecipientItem, true)
        let recovery = recovery(for: model, feed: try membersFeed())

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        guard case .added(let itemId) = recovery.phase else { return XCTFail("expected the episode to be added, got \(recovery.phase)") }
        let review = try XCTUnwrap(model.spokenMarginsPackageImportReview)
        XCTAssertEqual(review.matchingItemId, itemId, "the pending import found the episode that was just added")
        XCTAssertFalse(review.requiresRecipientItem)
        let item = try fixture.store.loadItem(id: itemId)
        XCTAssertEqual(item.title, "Episode 12: The Private One")
        XCTAssertEqual(item.media?.url, Self.episode12Audio, "the matching episode, not the feed's first")
        XCTAssertEqual(item.episodeGUID, "ep-12")
        XCTAssertEqual(item.showTitle, "Members Only Show")
        XCTAssertFalse(try fixture.store.listItems().contains { $0.media?.url == Self.episode13Audio }, "the newest episode was not added")

        // The pasted link is kept nowhere: not on the item, not in the diagnostics a listener can copy.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains(Self.pastedSecret))
        XCTAssertFalse(model.diagnostics.contains { $0.key.contains(Self.pastedSecret) || $0.value.contains(Self.pastedSecret) })
        let diagnostics = try XCTUnwrap(model.diagnosticsExportFileURL())
        defer { try? FileManager.default.removeItem(at: diagnostics) }
        XCTAssertFalse(try String(contentsOf: diagnostics, encoding: .utf8).contains(Self.pastedSecret))

        // The Margins import onto that episode, and importing the packet again adds nothing.
        model.confirmSpokenMarginsPackageImport()
        try await waitFor("the package import", timeoutNanoseconds: 5_000_000_000) {
            model.spokenMarginsPackageImportReview == nil && !model.isImportingSpokenMarginsPackage
        }
        let digest = try XCTUnwrap(fixture.manifest.contentDigest)
        let layer = try XCTUnwrap(try fixture.store.loadImportedCommentaryLayer(packageDigest: digest))
        XCTAssertEqual(layer.itemId, itemId)
        XCTAssertNotEqual(layer.sourceResolutionStatus, .wrongSource)

        model.handleIncomingURL(fixture.packageURL)
        await model.waitForPackageStaging()
        XCTAssertNil(model.spokenMarginsPackageImportReview, "already imported: there is nothing to confirm")
        XCTAssertEqual(model.diagnostics["lastSpokenMarginsPackageImport"], "duplicate:\(digest)")
        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()
        XCTAssertEqual(recovery.phase, .added(itemId: itemId), "pasting the feed again finds the episode already in the Library")
        XCTAssertEqual(try fixture.store.listItems().filter { $0.media?.url == Self.episode12Audio }.count, 1)
        XCTAssertEqual(try fixture.store.loadImportedCommentaryLayers(itemId: itemId).count, 1)
    }

    func testFriendsFeedThatTitlesTheShowDifferentlyStillMatchesTheEpisode() async throws {
        let fixture = try await makePrivateFeedFixture()
        let recovery = recovery(for: fixture.model, feed: try membersFeed(show: "Members Only Show (subscriber B)"))

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        guard case .added(let itemId) = recovery.phase else { return XCTFail("expected the episode to be added, got \(recovery.phase)") }
        XCTAssertEqual(fixture.model.spokenMarginsPackageImportReview?.matchingItemId, itemId)
        XCTAssertEqual(try fixture.store.loadItem(id: itemId).showTitle, "Members Only Show (subscriber B)")
        // The feed's GUID can be a link carrying the subscriber's token; no diagnostics key may carry it.
        XCTAssertFalse(fixture.model.diagnostics.keys.contains { $0.contains("ep-12") })
    }

    func testAnotherEpisodeOfTheSameShowIsNeverGivenThisEpisodesIdentity() async throws {
        let fixture = try await makePrivateFeedFixture()
        // An episode added before GUIDs were kept, whose feed link is the show's page for every episode.
        let other = Item(
            id: "other-episode", title: "Episode 11: The Earlier One", mediaType: "transcript_backed_media", text: nil,
            externalReference: "https://members.example/", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://media.members.example/ep11.mp3"))
        try fixture.store.saveItem(other)
        let recovery = recovery(for: fixture.model, feed: try membersFeed())

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        guard case .added(let itemId) = recovery.phase else { return XCTFail("expected the episode to be added, got \(recovery.phase)") }
        XCTAssertNotEqual(itemId, "other-episode")
        XCTAssertNil(try fixture.store.loadItem(id: "other-episode").episodeGUID)
        XCTAssertEqual(try fixture.store.loadItem(id: itemId).media?.url, Self.episode12Audio)
    }

    func testEpisodeAlreadyInTheLibraryIsReusedAndGainsTheIdentityItWasAddedWithout() async throws {
        let fixture = try await makePrivateFeedFixture()
        let model = fixture.model
        // The listener added the episode earlier by its audio link, which keeps no GUID, show or date.
        let existing = Item(
            id: "already-here", title: "Episode 12: The Private One", mediaType: "transcript_backed_media", text: nil,
            externalReference: nil, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: Self.episode12Audio, durationMs: 3_780_000))
        try fixture.store.saveItem(existing)
        let recovery = recovery(for: model, feed: try membersFeed())

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        XCTAssertEqual(recovery.phase, .added(itemId: "already-here"))
        XCTAssertEqual(try fixture.store.listItems().filter { $0.media?.url == Self.episode12Audio }.count, 1, "no second episode")
        let item = try fixture.store.loadItem(id: "already-here")
        XCTAssertEqual(item.episodeGUID, "ep-12")
        XCTAssertEqual(item.showTitle, "Members Only Show")
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, "already-here")
    }

    func testEpisodeAddedEarlierByItsAudioLinkUnderTheFileNameIsLeftAloneAndTheFeedsEpisodeIsAdded() async throws {
        let fixture = try await makePrivateFeedFixture()
        let model = fixture.model
        // Pasting the audio link titles the item from the file name, so the packet's title never matches it.
        let byAudioLink = Item(
            id: "by-audio-link", title: "ep12", mediaType: "transcript_backed_media", text: nil,
            externalReference: Self.episode12Audio, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: Self.episode12Audio, durationMs: 3_780_000))
        try fixture.store.saveItem(byAudioLink)
        let recovery = recovery(for: model, feed: try membersFeed())

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        guard case .added(let itemId) = recovery.phase else { return XCTFail("expected the episode to be added, got \(recovery.phase)") }
        XCTAssertNotEqual(itemId, "by-audio-link", "reusing it would leave the import refusing it")
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, itemId, "the pending import is importable")
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.requiresRecipientItem, false)
        XCTAssertEqual(try fixture.store.loadItem(id: itemId).title, "Episode 12: The Private One")
        let untouched = try fixture.store.loadItem(id: "by-audio-link")
        XCTAssertEqual(untouched.title, "ep12", "the listener's own item is left as it was")
        XCTAssertNil(untouched.episodeGUID)
        XCTAssertNil(untouched.showTitle)
    }

    func testEpisodeTheFeedMatchesByTitleAloneIsNotAddedWhenTheImportWouldRefuseIt() async throws {
        // A sender who added the episode by its audio link: the packet has a title and a length, no show and no day.
        let fixture = try await makePrivateFeedFixture(showTitle: nil, publishedAt: nil)
        let before = try fixture.store.listItems().count
        let recovery = recovery(for: fixture.model, feed: try membersFeed())

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        XCTAssertEqual(recovery.phase, .noMatch, "an episode the import can't match is not added")
        XCTAssertEqual(try fixture.store.listItems().count, before, "no extra episode in the Library")
        XCTAssertEqual(fixture.model.spokenMarginsPackageImportReview?.requiresRecipientItem, true)
    }

    func testPastedFeedWithoutTheEpisodeSaysSoAndAddsNothing() async throws {
        let fixture = try await makePrivateFeedFixture()
        let before = try fixture.store.listItems().count
        let recovery = recovery(for: fixture.model, feed: try membersFeed(includingEpisode12: false))

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        XCTAssertEqual(recovery.phase, .noMatch)
        XCTAssertEqual(try fixture.store.listItems().count, before)
        XCTAssertEqual(fixture.model.spokenMarginsPackageImportReview?.requiresRecipientItem, true, "the pending import is still waiting")
        recovery.reset()
        XCTAssertEqual(recovery.phase, .idle)
    }

    func testPastedFeedWithSeveralMatchingEpisodesAsksAndNeverGuesses() async throws {
        let fixture = try await makePrivateFeedFixture()
        let before = try fixture.store.listItems().count
        let secondAudio = "https://media.members.example/ep12-second.mp3"
        let feed = try parsedFeed([
            (title: "Episode 12: The Private One", guid: "ep-12-first", published: "Tue, 01 Sep 2026 00:00:00 +0000", minutes: 63, audio: Self.episode12Audio),
            (title: "Episode 12: The Private One", guid: "ep-12-second", published: "Tue, 01 Sep 2026 06:00:00 +0000", minutes: 63, audio: secondAudio)
        ])
        let recovery = recovery(for: fixture.model, feed: feed)

        await recovery.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)
        await fixture.model.waitForPackageStaging()

        guard case .choose(let candidates) = recovery.phase else { return XCTFail("expected a choice, got \(recovery.phase)") }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(try fixture.store.listItems().count, before, "nothing is added until the listener picks")

        await recovery.choose(candidates[1].id)
        await fixture.model.waitForPackageStaging()

        guard case .added(let itemId) = recovery.phase else { return XCTFail("expected the pick to be added, got \(recovery.phase)") }
        XCTAssertEqual(try fixture.store.loadItem(id: itemId).media?.url, secondAudio)
        XCTAssertFalse(try fixture.store.listItems().contains { $0.media?.url == Self.episode12Audio }, "only the pick was added")
        XCTAssertEqual(fixture.model.spokenMarginsPackageImportReview?.matchingItemId, itemId)
    }

    func testAFeedThatCannotBeReadFailsPlainlyWithoutAddingAnything() async throws {
        let fixture = try await makePrivateFeedFixture()
        let before = try fixture.store.listItems().count
        var services = SharedEpisodeRecovery.services(model: fixture.model)
        services.fetchFeed = { _ in throw URLError(.notConnectedToInternet) }
        let offline = SharedEpisodeRecovery(services: services)

        await offline.recover(fixture.manifest.item, feedLink: Self.pastedFeedLink)

        XCTAssertEqual(offline.phase, .failed(SharedEpisodeRecovery.message(for: URLError(.notConnectedToInternet))))
        XCTAssertFalse(SharedEpisodeRecovery.message(for: URLError(.timedOut)).contains(Self.pastedSecret))
        XCTAssertNotEqual(
            SharedEpisodeRecovery.message(for: URLError(.timedOut)), SharedEpisodeRecovery.message(for: FeedParserError.malformed))

        await offline.recover(fixture.manifest.item, feedLink: "not a link")
        XCTAssertEqual(offline.phase, .failed(SharedEpisodeRecovery.invalidLinkMessage))
        XCTAssertEqual(try fixture.store.listItems().count, before)
    }

    func testFeedLinksFromPodcastAppsAreReadAsHTTPSAndAnythingElseIsRefused() {
        let accepted = [
            " https://a.example/f.rss \n": "https://a.example/f.rss",
            "https://a.example/f.rss?auth=x": "https://a.example/f.rss?auth=x",
            "feed://a.example/f.rss": "https://a.example/f.rss",
            "FEED://a.example/f.rss": "https://a.example/f.rss",
            "itpc://a.example/f.rss": "https://a.example/f.rss",
            "pcast://a.example/f.rss": "https://a.example/f.rss",
            "feed:https://a.example/f.rss": "https://a.example/f.rss"
        ]
        for (pasted, expected) in accepted {
            XCTAssertEqual(SharedEpisodeRecovery.feedURL(from: pasted)?.absoluteString, expected, pasted)
        }
        for pasted in ["", "   ", "not a link", "a.example/f.rss", "http://a.example/f.rss", "ftp://a.example/f.rss", "https://", "file:///etc/passwd", "javascript:alert(1)"] {
            XCTAssertNil(SharedEpisodeRecovery.feedURL(from: pasted), pasted)
        }
    }
}

private struct EchoAudioLinkResolver: LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: request.inputURL, role: "media"),
                title: "audio", audioURL: request.inputURL, confidence: 1)
        )
    }
}

private struct SourceLinkFoundationModelStub: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability { .available }
    func summarizeInterjections(context: String) async throws -> String { "Summary" }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        LocalListeningMapLabel(title: "Chapter \(chapterNumber)", description: "A bounded chapter description.")
    }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        "A bounded map overview."
    }
}

private struct ThrowingAppLinkResolver: LinkResolutionClient {
    var error: Error

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        throw error
    }
}

private struct StaticAppLinkResolver: LinkResolutionClient {
    var result: LinkResolutionResult

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(url: request.inputURL, provider: result.originalLink.provider, title: result.originalLink.title, role: result.originalLink.role),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private final class VoiceoverFeedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let feedData = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
    <channel><title>Voiceovers</title><link>https://voiceovers.example</link><generator>Substack</generator>
    <item><title>A post with a voiceover</title><link>https://voiceovers.example/p/post</link><guid>post</guid>
    <description>Subtitle.</description><enclosure url="https://cdn.voiceovers.example/post.mp3" type="audio/mpeg"/>
    <itunes:duration>1312</itunes:duration>
    <content:encoded><![CDATA[<p>\(String(repeating: "Listening in the margins. ", count: 180))</p>]]></content:encoded></item>
    <item><title>An episode</title><link>https://voiceovers.example/p/episode</link><guid>episode</guid>
    <description>Subtitle.</description><enclosure url="https://cdn.voiceovers.example/episode.mp3" type="audio/mpeg"/>
    <content:encoded><![CDATA[<p>Show notes for the episode.</p>]]></content:encoded></item>
    <item><title>A text-only post</title><link>https://voiceovers.example/p/text-only</link><guid>text-only</guid>
    <description>Subtitle.</description>
    <content:encoded><![CDATA[<p>\(String(repeating: "Notes from the archive. ", count: 40))</p>]]></content:encoded></item>
    </channel></rss>
    """.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "voiceovers.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/rss+xml"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/p/post" {
            let post: [String: Any] = ["id": 1, "type": "newsletter", "has_voiceover": true,
                "canonical_url": "https://voiceovers.example/p/post", "audio_items": [
                    ["post_id": 1, "type": "voiceover", "status": "completed", "audio_url": "https://cdn.voiceovers.example/post.mp3"]]]
            let json = try! JSONSerialization.data(withJSONObject: ["post": post], options: [.sortedKeys, .withoutEscapingSlashes])
            let encoded = try! JSONEncoder().encode(String(decoding: json, as: UTF8.self))
            client?.urlProtocol(self, didLoad: Data("<script>window._preloads = JSON.parse(\(String(decoding: encoded, as: UTF8.self)));</script>".utf8))
        } else {
            client?.urlProtocol(self, didLoad: Self.feedData)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LargePodcastFeedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let feedData: Data = {
        let padding = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
        let items = (1...30).map { day in
            let paddedDay = String(format: "%02d", day)
            return """
            {"id":"episode-\(day)","url":"https://example.com/episodes/\(day)","title":"Episode \(day)","date_published":"2026-08-\(paddedDay)T12:00:00Z","attachments":[
            {"url":"https://cdn.example.com/episode-\(day).mp3","mime_type":"audio/mpeg"}]}
            """
        }.joined(separator: ",")
        return Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"Large Podcast","padding":"\(padding)","items":[
        \(items)]}
        """.utf8)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/feed+json",
                    "Content-Length": "\(Self.feedData.count)"
                ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.feedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CountingAppLinkResolver: LinkResolutionClient {
    var result: LinkResolutionResult
    private(set) var resolveCount = 0

    init(result: LinkResolutionResult) {
        self.result = result
    }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        resolveCount += 1
        return LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(url: request.inputURL, provider: result.originalLink.provider, title: result.originalLink.title, role: result.originalLink.role),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private struct ThrowingSourceTranscriptionClient: SourceTranscriptionClient {
    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_test")
    }
}

private final class WindowContextAudioClient: AudioPlaybackClient {
    private(set) var lastMediaContext: PlaybackMediaContext?
    private var durationMs = 300_000

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        lastMediaContext = context
        if let duration = context?.durationMs { durationMs = duration }
    }

    var currentMediaTimeValue: Int?
    private var activeTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        activeTargetId = targetId
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        currentMediaTimeValue = mediaTimeMs
    }

    func pause() throws {}

    func currentPlaybackPosition() -> PlaybackPosition? {
        guard let currentMediaTimeValue else { return nil }
        return PlaybackPosition(
            targetType: .transcriptBackedMedia,
            targetId: activeTargetId,
            mediaTimeMs: currentMediaTimeValue,
            durationMs: durationMs,
            playbackRate: 1,
            anchorConfidence: .mediaTime
        )
    }
}

extension SourceLinkImportTests {
    /// Points the model's heard-audio files at an empty temporary folder, so a test can see exactly what is left (#652).
    func makeHeardWindowRoot(for model: Gate1AppModel) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "heard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        model.heardSourceWindows = HeardSourceWindowFiles(rootDirectory: root)
        return root
    }

    /// Stands in for the player's audio tap, which these tests don't run: hands the model the audio heard around the
    /// first Margin (#156). Silent samples are enough; the fake transcriber doesn't read them.
    func deliverHeardWindow(to model: Gate1AppModel, anchorMs: Int, startMs: Int, durationMs: Int) async throws {
        let margin = try XCTUnwrap(model.selectedItem.interjections.first, "the Margin should be saved before its heard audio arrives")
        let request = PostResumeAudioSampleRequest(
            interjectionId: margin.id, sessionId: margin.sessionId, itemId: margin.itemId,
            anchorMediaTimeMs: anchorMs, targetDurationMs: 11_000
        )
        await model.handleHeardSourceWindow(HeardAudioWindow(
            request: request, sampleRate: 1_000,
            segments: [.init(startMediaTimeMs: startMs, samples: [Float](repeating: 0, count: durationMs))],
            endReason: "complete"
        ))
    }
}

private actor RecordingSourceWindowTranscriptionClient: SourceTranscriptionClient {
    struct WindowRequest: Sendable {
        var url: URL
        var anchorMediaTimeMs: Int
        var durationMs: Int?
        var windowBeforeMs: Int
        var windowAfterMs: Int
    }

    private let timeline: TranscriptTimeline
    private var windowRequest: WindowRequest?
    private var continuations: [CheckedContinuation<WindowRequest, Never>] = []

    init(timeline: TranscriptTimeline) {
        self.timeline = timeline
    }

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_test")
    }

    func transcribeSourceAudioWindow(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) async throws -> TranscriptTimeline {
        let request = WindowRequest(
            url: url,
            anchorMediaTimeMs: anchorMediaTimeMs,
            durationMs: durationMs,
            windowBeforeMs: windowBeforeMs,
            windowAfterMs: windowAfterMs
        )
        windowRequest = request
        for continuation in continuations {
            continuation.resume(returning: request)
        }
        continuations.removeAll()
        return timeline
    }

    func waitForWindowRequest() async -> WindowRequest {
        if let windowRequest {
            return windowRequest
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func windowRequestCount() -> Int {
        windowRequest == nil ? 0 : 1
    }
}

/// Holds each source-window job until the test lets it go, and counts how many run at once (#1308, ANC-03). Main-actor
/// state, so the test reads it without awaiting, and the jobs (which the model's queue runs on the main actor) update
/// it in order.
@MainActor
private final class GatedSourceWindowTranscriptionClient: SourceTranscriptionClient {
    private(set) var runningNow = 0
    private(set) var peakRunning = 0
    private(set) var startedAnchors: [Int] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    nonisolated func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_test")
    }

    nonisolated func transcribeSourceAudioWindow(
        url: URL, itemId: String, anchorMediaTimeMs: Int, durationMs: Int?, windowBeforeMs: Int, windowAfterMs: Int
    ) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_window_without_evidence_disabled_for_test")
    }

    func transcribeSourceAudioWindowWithEvidence(
        url: URL, itemId: String, anchorMediaTimeMs: Int, durationMs: Int?, windowBeforeMs: Int, windowAfterMs: Int
    ) async throws -> SourceAudioWindowTranscription {
        runningNow += 1
        peakRunning = max(peakRunning, runningNow)
        startedAnchors.append(anchorMediaTimeMs)
        await withCheckedContinuation { waiting.append($0) }
        runningNow -= 1
        return SourceAudioWindowTranscription(
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "context-\(anchorMediaTimeMs)", startMs: max(0, anchorMediaTimeMs - 1_000),
                                                endMs: anchorMediaTimeMs + 1_000, text: "Context near the Margin.")],
                chapters: [],
                durationMs: durationMs
            ),
            localAudioURL: nil,
            sourceStartMs: max(0, anchorMediaTimeMs - windowBeforeMs),
            sourceEndMs: anchorMediaTimeMs + windowAfterMs,
            provenance: .sourceWindowReference
        )
    }

    /// Lets every job that is waiting finish.
    func releaseWaiting() {
        let released = waiting
        waiting = []
        for job in released { job.resume() }
    }
}

private actor RecordingFullSourceTranscriptionClient: SourceTranscriptionClient {
    struct FullRequest: Sendable {
        var url: URL
        var itemId: String
        var durationMs: Int?
    }

    private var requests: [FullRequest] = []
    private var continuations: [CheckedContinuation<FullRequest, Never>] = []

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        let request = FullRequest(url: url, itemId: itemId, durationMs: durationMs)
        requests.append(request)
        for continuation in continuations {
            continuation.resume(returning: request)
        }
        continuations.removeAll()
        return TranscriptTimeline(
            segments: [
                MediaTimelineSegment(
                    id: "full-source-segment",
                    startMs: 0,
                    endMs: max(1, durationMs ?? 1),
                    text: "The full source is derived only for a requested Listening Map."
                )
            ],
            chapters: [],
            durationMs: durationMs
        )
    }

    func fullRequestCount() -> Int {
        requests.count
    }

    func waitForFullRequest() async -> FullRequest {
        if let request = requests.last {
            return request
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private actor ControlledInterjectionTranscriber {
    private var requested = false
    private var requestContinuations: [CheckedContinuation<Void, Never>] = []
    private var transcriptContinuation: CheckedContinuation<String, Error>?

    func transcribe(audioPath: String) async throws -> String {
        requested = true
        for continuation in requestContinuations {
            continuation.resume()
        }
        requestContinuations.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            transcriptContinuation = continuation
        }
    }

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    func complete(with transcript: String) {
        transcriptContinuation?.resume(returning: transcript)
        transcriptContinuation = nil
    }
}

/// A transcriber whose every call waits until the test settles it, in the order the calls arrived.
private actor GatedInterjectionTranscriber {
    private var waiting: [CheckedContinuation<String, Error>] = []
    private var requestCount = 0

    func transcribe(audioPath: String) async throws -> String {
        requestCount += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    /// True once `count` calls have reached the transcriber, false after about two seconds.
    func waitUntilRequested(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if requestCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func settleNext(_ result: Result<String, Error>) {
        guard !waiting.isEmpty else {
            XCTFail("no transcription is waiting to be settled")
            return
        }
        waiting.removeFirst().resume(with: result)
    }
}

@MainActor
private final class RedirectedFeedArticleExtractor: ReadablePageExtracting {
    let capture: BrowserTextHandoff
    init(capture: BrowserTextHandoff) { self.capture = capture }
    var lastExtractor: String? { "redirected-test-capture" }
    var contactedHosts: [String] { ["publisher.example", "destination.example"] }
    func extract(url: URL) async throws -> BrowserTextHandoff { capture }
}

/// Holds every page fetch until the test opens it, so a Play now can still be waiting when the listener
/// starts something else (#2124).
private final class GatedFeedArticleExtractor: ReadablePageExtracting, @unchecked Sendable {
    let capture: BrowserTextHandoff
    private let lock = NSLock()
    private var isOpen = false
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(capture: BrowserTextHandoff) { self.capture = capture }
    var lastExtractor: String? { "gated-test-capture" }
    var contactedHosts: [String] { ["publisher.example"] }
    var callCount: Int { lock.withLock { calls } }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    func extract(url: URL) async throws -> BrowserTextHandoff {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                calls += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return capture
    }
}

private final class AliasedFeedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isArticle = request.url?.path == "/article"
        let body = isArticle
            ? "<html><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/feed\"></html>"
            : "<rss version=\"2.0\"><channel><title>Publisher</title><link>https://example.com</link><item><title>Article</title><link>https://example.com/article</link></item></channel></rss>"
        let response = HTTPURLResponse(url: URL(string: isArticle ? "https://example.com/article" : "https://example.com/canonical-feed")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isArticle ? "text/html" : "application/rss+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension Gate1AppModel {
    /// Per-Margin diagnostics are keyed by a session token; these tests run a single session.
    func marginDiagnostic(_ name: String, interjectionId: String) -> String? {
        diagnostics.first { $0.key.hasPrefix("\(name):") && $0.key.hasSuffix("/\(interjectionId)") }?.value
    }
}

@MainActor
private final class RefusingPublisherPageExtractor: ReadablePageExtracting {
    var calls = 0
    private let result: BrowserTextHandoff?
    init(result: BrowserTextHandoff? = nil) { self.result = result }
    var lastExtractor: String? { "unauthenticated-page" }
    var contactedHosts: [String] { [] }
    func extract(url: URL) async throws -> BrowserTextHandoff {
        calls += 1
        if let result { return result }
        throw URLError(.userAuthenticationRequired)
    }
}

/// A share candidate the walk can carry across queues, as the extension's own `ProviderCandidate` is.
private struct SharedCandidate: @unchecked Sendable {
    let provider: NSItemProvider
    let identifier: String
}

/// The test's handoff store, which the walk's loaders use from the providers' queues.
private struct SharedPDFStore: @unchecked Sendable {
    let store: SourceLinkHandoffStore
}

/// What the share walk handed off, set once from its completion.
private final class ShareWalkResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<(url: URL, surface: String), Error>??

    func set(_ result: Result<(url: URL, surface: String), Error>?) {
        lock.withLock { stored = .some(result) }
    }

    var result: Result<(url: URL, surface: String), Error>? {
        lock.withLock { stored ?? nil }
    }
}

/// What a canned share walk handed off. The walk runs its steps inline, so no lock is needed.
private final class WalkedShare: @unchecked Sendable {
    var value: String?
}

private extension ShareSheetCandidateOutcome {
    var isLinkOutcome: Bool {
        if case .link = self { return true }
        return false
    }
}
