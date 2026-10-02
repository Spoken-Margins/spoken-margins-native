import XCTest
import SessionKit
import SessionKitPersistence
import SessionKitAudio
import SessionKitFeeds
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

    func testFeedAliasesUseFinalResponseIdentityWithoutSelfLink() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AliasedFeedURLProtocol.self]
        let coordinator = FollowedSourceCoordinator(repository: InMemorySessionRepository(), session: URLSession(configuration: configuration))
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
        let coordinator = FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration))

        let subscription = try await coordinator.follow(urlString: "https://voiceovers.example/feed")

        XCTAssertEqual(subscription.source.kind, .podcastFeed, "a feed with audio is still followed as it was")
        let entries = try repository.loadFeedEntries(subscriptionId: subscription.id)
        let post = try XCTUnwrap(entries.first { $0.title == "A post with a voiceover" })
        let episode = try XCTUnwrap(entries.first { $0.title == "An episode" })
        XCTAssertGreaterThanOrEqual(post.bodyWordCount ?? 0, 700)
        XCTAssertEqual(post.audioDurationMs, 1_312_000)
        XCTAssertFalse(post.hasPublisherAudio, "length alone is ambiguous")
        let confirmed = await coordinator.publisherAudioEntry(for: post)
        XCTAssertTrue(confirmed.hasPublisherAudio)
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: confirmed, itemId: "item")?.audioURL, "https://cdn.voiceovers.example/post.mp3")
        XCTAssertFalse(episode.hasPublisherAudio, "an episode with short notes imports as audio, as before")
        XCTAssertNil(PublisherAudioDetector.publisherAudio(for: episode, itemId: "item"))
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
            let feed = "<rss><channel><item><title>Private publisher narration</title><content:encoded xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"><![CDATA[\(html)]]></content:encoded></item></channel></rss>"
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
            XCTAssertEqual(extractor.calls, 0, "a public 403/teaser must never replace accessible feed text")
            XCTAssertEqual(model.snapshot.sessionId, activeSession)
            XCTAssertEqual(model.selectedItem.id, openWhenFinished ? item.id : "item-pill")
        }
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
            session: URLSession(configuration: configuration)
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

        try deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)
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
        try deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)

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
        let transcriber = SequencedInterjectionTranscriber(transcripts: [
            "Only the ending survived.",
            "The complete saved interjection is restored from its original audio."
        ])
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
        try await waitFor("initial transcript") {
            model.selectedItem.interjections.first?.transcript == "Only the ending survived."
        }
        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)

        model.retryInterjectionTranscription(interjection)
        try await waitFor("replacement transcript") {
            model.selectedItem.interjections.first?.transcript == "The complete saved interjection is restored from its original audio."
        }

        XCTAssertFalse(model.retryingInterjectionTranscriptionIds.contains(interjection.id))
        XCTAssertEqual(model.diagnostics[Gate1AppModel.marginDiagnosticKey("interjectionTranscription", interjection)], "complete")

        let recovered = try XCTUnwrap(model.selectedItem.interjections.first)
        model.retryInterjectionTranscription(recovered)
        try await waitFor("failed retry evidence") {
            model.diagnostics[Gate1AppModel.marginDiagnosticKey("interjectionTranscription", interjection)]?.hasPrefix("retry_failed:") == true
        }

        XCTAssertEqual(model.selectedItem.interjections.first?.transcript, "The complete saved interjection is restored from its original audio.")
        XCTAssertEqual(model.selectedItem.interjections.first?.displayText, "The complete saved interjection is restored from its original audio.")
        XCTAssertFalse(model.retryingInterjectionTranscriptionIds.contains(interjection.id))
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
        try deliverHeardWindow(to: model, anchorMs: 123_000, startMs: 63_000, durationMs: 120_000)
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

    func testStoredTranscriptWindowUsesFullShoulderAndAllowsTimestampGaps() throws {
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "early", startMs: 35_000, endMs: 55_000, text: "Earlier context."),
                MediaTimelineSegment(id: "before", startMs: 70_000, endMs: 120_000, text: "Before."),
                MediaTimelineSegment(id: "after", startMs: 125_000, endMs: 175_000, text: "After."),
                MediaTimelineSegment(id: "late", startMs: 200_000, endMs: 240_000, text: "Later context."),
                MediaTimelineSegment(id: "far", startMs: 500_000, endMs: 550_000, text: "Far away.")
            ],
            chapters: [],
            durationMs: 600_000
        )

        let window = try XCTUnwrap(Gate1AppModel.sourceContextWindow(from: timeline, anchorMediaTimeMs: 123_000))

        XCTAssertEqual(
            window.segments.map(\.id),
            ["early", "before", "after", "late"],
            "The stored transcript should preserve the full 90-second/120-second shoulder despite normal word-timestamp gaps"
        )
        XCTAssertNil(Gate1AppModel.sourceContextWindow(from: timeline, anchorMediaTimeMs: 350_000))
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
        try await waitFor("unsupported share quarantine") {
            (try? store.failedHandoffs().count) == 1
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
        try await waitFor("shared episode import") {
            model.libraryItems.contains { $0.title == "Shared Episode" }
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
            model.libraryItems.contains { $0.title == "Transcript Race Podcast" }
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
            model.libraryItems.contains { $0.title == "Pending Episode" }
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
        timeoutNanoseconds: UInt64 = 1_000_000_000,
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
    /// Stands in for the player's audio tap, which these tests don't run: hands the model the audio heard around the
    /// first Margin (#156). Silent samples are enough; the fake transcriber doesn't read them.
    func deliverHeardWindow(to model: Gate1AppModel, anchorMs: Int, startMs: Int, durationMs: Int) throws {
        let margin = try XCTUnwrap(model.selectedItem.interjections.first, "the Margin should be saved before its heard audio arrives")
        let request = PostResumeAudioSampleRequest(
            interjectionId: margin.id, sessionId: margin.sessionId, itemId: margin.itemId,
            anchorMediaTimeMs: anchorMs, targetDurationMs: 11_000
        )
        model.handleHeardSourceWindow(HeardAudioWindow(
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

private actor SequencedInterjectionTranscriber {
    private var transcripts: [String]

    init(transcripts: [String]) {
        self.transcripts = transcripts
    }

    func transcribe(audioPath: String) throws -> String {
        guard !transcripts.isEmpty else {
            throw SessionKitError.persistenceFailed("no_scripted_transcript")
        }
        return transcripts.removeFirst()
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
