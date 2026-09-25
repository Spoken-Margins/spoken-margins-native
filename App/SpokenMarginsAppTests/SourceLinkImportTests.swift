import XCTest
import SessionKit
import SessionKitPersistence
import AVFoundation
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SourceLinkImportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    func testDescriptionChaptersAcceptLinkedParenthesesAndPreserveTitleColons() throws {
        let chapters = try XCTUnwrap(TimestampedDescriptionChapterParser.parse("""
        <p>Episode notes with unrelated <a href="https://example.com?t=99">links</a>.</p>
        <div>(<a href="https://example.com/watch?t=0">00:00:00</a>) &ndash; AI: the opening question</div>
        <div><a href="https://example.com/watch?t=942">(00:15:42)</a>&nbsp;— Evidence &amp; uncertainty</div>
        <p>[01:02:03](https://example.com/watch?t=3723) | What&#39;s next?</p>
        """))
        XCTAssertEqual(chapters.source, .timestampedDescription)
        XCTAssertEqual(chapters.chapters, [
            PublisherChapter(title: "AI: the opening question", startMs: 0),
            PublisherChapter(title: "Evidence & uncertainty", startMs: 942_000),
            PublisherChapter(title: "What's next?", startMs: 3_723_000)
        ])
    }

    func testDescriptionChaptersValidateTimesAndIgnoreProseAndURLOnlyLines() throws {
        let chapters = try XCTUnwrap(TimestampedDescriptionChapterParser.parse("""
        Released at 12:30 on Tuesday.
        00:60 Invalid seconds
        01:75:00 Invalid minutes
        [00:02) Mismatched brackets
        00:03garbage
        00:04 https://example.com
        <script>00:05 Script content</script>
        • [120:00] Long introduction
        00:00.250 - First thought
        00:00.250 - First thought
        00&#58;30&#160;– A second thought
        """))
        XCTAssertEqual(chapters.chapters.map(\.startMs), [250, 30_000, 7_200_000])
        XCTAssertEqual(chapters.chapters.map(\.title), ["First thought", "A second thought", "Long introduction"])
        XCTAssertNil(TimestampedDescriptionChapterParser.parse("00:00 Only one chapter"))
        XCTAssertNil(TimestampedDescriptionChapterParser.parse(String(repeating: "x", count: 1_000_001)))
    }

    func testFeedDescriptionChaptersSurviveAnEarlierShortSummary() throws {
        let feed = """
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Show</title><item><title>Episode</title>
        <enclosure url="https://example.com/episode.mp3" type="audio/mpeg" />
        <description>A brief summary without chapters.</description>
        <content:encoded><![CDATA[<p>(00:00) – Opening</p><p>(12:30) – Discussion</p>]]></content:encoded>
        </item></channel></rss>
        """
        let request = LinkResolutionRequest(id: "description-fallback", inputURL: "https://example.com/feed.xml", sourceSurface: "paste", createdAt: Date())
        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(feed.utf8) }).resolve(request)
        let collections = try XCTUnwrap(result.selectedCandidate).publisherChapterCollections
        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.first?.source, .timestampedDescription)
        XCTAssertEqual(collections.first?.chapters.map(\.startMs), [0, 750_000])
    }

    func testExactAppleEpisodeRetainsSevenChaptersWhenFeedReturns403() async throws {
        // Shape and times from Apple episode 1000774870615; prose is synthetic.
        let times = ["00:00:00", "00:11:32", "00:26:12", "00:38:08", "00:53:48", "01:07:07", "01:16:02"]
        let description = times.enumerated().map { "(\($0.element)) – Topic \($0.offset + 1)" }.joined(separator: "\n")
        let data = try JSONSerialization.data(withJSONObject: ["results": [[
            "trackId": 1000774870615, "kind": "podcast-episode",
            "trackName": "Grant Sanderson – AI and the future of math",
            "collectionName": "Dwarkesh Podcast", "trackTimeMillis": 5619000,
            "feedUrl": "https://feed.example/forbidden.rss", "episodeUrl": "https://audio.example/episode.mp3",
            "description": description, "shortDescription": "Summary without chapters"
        ]]])
        let fetch: @Sendable (URL) throws -> Data = { url in
            guard url.host == "itunes.apple.com" else { throw URLError(.badServerResponse) }
            return data
        }
        let resolver = PublicPodcastLinkResolver(fetch: fetch, asynchronousFetch: { try fetch($0) })
        let request = LinkResolutionRequest(id: "exact-apple", inputURL: "https://podcasts.apple.com/us/podcast/dwarkesh-podcast/id1516093381?i=1000774870615", sourceSurface: "paste", createdAt: Date())
        let synchronous = try resolver.resolve(request)
        let asynchronous = try await resolver.resolveAsync(request)
        for result in [synchronous, asynchronous] {
            XCTAssertEqual(result.status, .playable)
            let candidate = try XCTUnwrap(result.selectedCandidate)
            XCTAssertEqual(candidate.durationMs, 5_619_000)
            XCTAssertEqual(candidate.publisherChapterCollections.first?.chapters.map(\.startMs), [0, 692000, 1572000, 2288000, 3228000, 4027000, 4562000])
            XCTAssertEqual(candidate.publisherChapterCollections.first?.source, .timestampedDescription)
        }
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
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
        let entry = FeedEntry(id: "entry", subscriptionId: subscription.id, canonicalURL: "https://publisher.example/episode", audioURL: audioURL, title: "Actual episode title", author: "Actual author", summary: "00:00 Opening\n02:00 Discussion")
        try store.saveFeedEntry(entry)
        model.importFollowedSourceEntry(entry)
        try await waitFor("feed entry import") { model.libraryItems.contains { $0.title == entry.title } }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == entry.title })
        let persisted = try store.loadItem(id: row.id)
        XCTAssertEqual(persisted.sourceTitle, "Actual Publisher")
        XCTAssertEqual(persisted.sourceURL, subscription.source.canonicalURL)
        XCTAssertEqual(persisted.externalReference, entry.canonicalURL)
        XCTAssertEqual(persisted.author, "Actual author")
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

    func testNativeAudioInterjectionRequestsFullShoulderContext() async throws {
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
        let transcriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "window-early", startMs: 33_000, endMs: 62_000, text: "Earlier context."),
                MediaTimelineSegment(id: "window-before", startMs: 63_000, endMs: 122_000, text: "Minute before."),
                MediaTimelineSegment(id: "window-current", startMs: 122_000, endMs: 124_000, text: "Interjection context."),
                MediaTimelineSegment(id: "window-after", startMs: 124_000, endMs: 183_000, text: "Minute after."),
                MediaTimelineSegment(id: "window-late", startMs: 184_000, endMs: 243_000, text: "Later context.")
            ],
            chapters: [],
            durationMs: 300_000
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
        let request = await transcriber.waitForWindowRequest()
        try await waitFor("source window context to attach") {
            model.diagnostics["sourceWindowTranscription:ij-001"] == "complete:speech_window"
        }

        XCTAssertEqual(request.anchorMediaTimeMs, 123_000)
        XCTAssertEqual(request.windowBeforeMs, 90_000)
        XCTAssertEqual(request.windowAfterMs, 120_000)
        XCTAssertEqual(request.durationMs, 300_000)
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorBefore, "Earlier context. Minute before. Interjection context.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorAfter, "Minute after. Later context.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchorContextStatus, .ready)
        XCTAssertEqual(model.diagnostics["sourceWindowContextProvenance:ij-001"], "bounded_remote_window")
    }

    func testAcquiredWindowFeedsASRWithAbsoluteSourceTimesWithoutRefetch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let windowURL = root.appending(path: "shared-window.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000 * 24))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / 24_000
            samples[index] = Float(0.2 * sin(2 * .pi * (250 * time + 20 * time * time)))
        }
        try AVAudioFile(forWriting: windowURL, settings: format.settings).write(from: buffer)
        let transcriber = AcquiredWindowTranscriptionClient(windowURL: windowURL)
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored", status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Shared Window", durationMs: 300_000,
                audioURL: "https://cdn.example.com/window.mp3", confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver, audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(), sourceTranscriptionClient: transcriber,
            interjectionTranscriptionHandler: { _ in "My note." }
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("acquired context") {
            model.diagnostics["sourceWindowTranscription:ij-001"] == "complete:speech_window"
        }
        let calls = await transcriber.calls()
        XCTAssertEqual(calls.acquisitions, 1)
        XCTAssertEqual(calls.acquiredTranscriptions, 1)
        XCTAssertEqual(calls.originalURLTranscriptions, 0)
        XCTAssertEqual(calls.acquiredURL, windowURL)
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorBefore, "Before the note. At the note.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorAfter, "After the note.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchorContextStatus, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: windowURL.path), "A client-owned acquired file must remain available")
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

        let sourceRequestsBeforeNoteFinished = await sourceTranscriber.windowRequestCount()
        XCTAssertEqual(sourceRequestsBeforeNoteFinished, 0)

        await interjectionTranscriber.complete(with: "My recorded note.")
        _ = await sourceTranscriber.waitForWindowRequest()
        try await waitFor("both transcription stages to finish") {
            model.diagnostics["sourceWindowTranscription:ij-001"] == "complete:speech_window"
        }

        XCTAssertEqual(model.diagnostics["interjectionTranscription:ij-001"], "complete")
        XCTAssertEqual(
            model.diagnostics["interjectionAnchorAtCapture:ij-001"],
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
        XCTAssertEqual(model.diagnostics["interjectionTranscription:\(interjection.id)"], "complete")

        let recovered = try XCTUnwrap(model.selectedItem.interjections.first)
        model.retryInterjectionTranscription(recovered)
        try await waitFor("failed retry evidence") {
            model.diagnostics["interjectionTranscription:\(interjection.id)"]?.hasPrefix("retry_failed:") == true
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

    func testPublicResolverAcceptsDirectAudioURL() throws {
        let request = LinkResolutionRequest(
            id: "request-direct",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data() }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, request.inputURL)
        XCTAssertEqual(result.originalLink.provider, "direct_audio")
    }

    func testPublicResolverRejectsInsecureHTTPBeforeFetching() throws {
        let request = LinkResolutionRequest(
            id: "request-http",
            inputURL: "http://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in throw URLError(.badURL) }).resolve(request)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.failureReason, "invalid_url")
    }

    func testPublicResolverAsyncAcceptsDirectAudioURL() async throws {
        let request = LinkResolutionRequest(
            id: "request-direct-async",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try await PublicPodcastLinkResolver().resolveAsync(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, request.inputURL)
        XCTAssertEqual(result.originalLink.provider, "direct_audio")
    }

    func testPublicResolverExtractsRSSAudioEnclosure() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters">
          <channel>
            <title>Example Show</title>
            <item>
              <title>Episode One</title>
              <guid>episode-one</guid>
              <pubDate>Fri, 19 Jun 2026 12:00:00 GMT</pubDate>
              <itunes:duration>00:30:00</itunes:duration>
              <enclosure url="https://cdn.example.com/episode-one.mp3" type="audio/mpeg" length="1" />
              <podcast:transcript url="https://cdn.example.com/episode-one.vtt" type="text/vtt" language="en" rel="captions" />
              <podcast:chapters url="https://cdn.example.com/episode-one-chapters.json" type="application/json+chapters" />
              <psc:chapters version="1.2">
                <psc:chapter start="0" title="Podlove Intro" />
                <psc:chapter start="12:30.250" title="Podlove Topic" />
              </psc:chapters>
              <description><![CDATA[
                00:00 Description Intro<br />
                15:00 Description Topic
              ]]></description>
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-rss",
            inputURL: "https://feeds.example.com/show.xml",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let chapterJSON = """
        {
          "version": "1.2.0",
          "chapters": [
            { "startTime": 0, "title": "Publisher Intro" },
            { "startTime": 600.5, "title": "Publisher Topic" },
            { "startTime": 900, "title": "Silent Artwork", "toc": false }
          ]
        }
        """
        let result = try PublicPodcastLinkResolver(fetch: { url in
            url.path.hasSuffix("episode-one-chapters.json") ? Data(chapterJSON.utf8) : Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Episode One")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Example Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/episode-one.mp3")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 1_800_000)
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks, [
            SourceTranscriptLink(
                url: "https://cdn.example.com/episode-one.vtt",
                type: "text/vtt",
                language: "en",
                rel: "captions"
            )
        ])
        XCTAssertEqual(result.selectedCandidate?.chapterLinks, [
            SourceChapterLink(
                url: "https://cdn.example.com/episode-one-chapters.json",
                type: "application/json+chapters"
            )
        ])
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.map(\.source), [
            .podcasting20JSON,
            .podloveSimpleChapters,
            .timestampedDescription
        ])
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections[0].chapters, [
            PublisherChapter(title: "Publisher Intro", startMs: 0),
            PublisherChapter(title: "Publisher Topic", startMs: 600_500)
        ])
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections[1].chapters[1].startMs, 750_250)
    }

    func testPublicResolverAcceptsLegacyPodcastingNamespaceUsedByNoAgendaFeed() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md">
          <channel>
            <title>No Agenda Show</title>
            <item>
              <title>1891 - "We Need Memes!"</title>
              <guid>http://1891.noagendanotes.com</guid>
              <enclosure url="https://op3.dev/e/example/NA-1891-Final.mp3" type="audio/mpeg" length="1" />
              <podcast:transcript url="https://mp3s.nashownotes.com/NA-1891-Captions.srt" type="application/srt" rel="captions" />
              <podcast:chapters url="https://chapters.example.com/NA-1891-Chapters.json" type="application/json" />
            </item>
          </channel>
        </rss>
        """
        let chapterJSON = """
        {"version":"1.2.0","chapters":[
          {"startTime":0,"title":"Show Open"},
          {"startTime":150.74,"title":"Producer Context"}
        ]}
        """
        let lookup = """
        {"resultCount":1,"results":[{
          "wrapperType":"track",
          "kind":"podcast",
          "trackId":269169796,
          "collectionName":"No Agenda Show",
          "feedUrl":"https://feeds.noagendaassets.com/noagenda.xml"
        }]}
        """
        let request = LinkResolutionRequest(
            id: "request-no-agenda-apple",
            inputURL: "https://podcasts.apple.com/us/podcast/1891-we-need-memes/id269169796?i=1000779583526",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "itunes.apple.com" { return Data(lookup.utf8) }
            if url.host == "feeds.noagendaassets.com" { return Data(feed.utf8) }
            if url.host == "chapters.example.com" { return Data(chapterJSON.utf8) }
            throw URLError(.badURL)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "1891 - \"We Need Memes!\"")
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks.first?.type, "application/srt")
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.source, .podcasting20JSON)
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.chapters[1].startMs, 150_740)
    }

    func testPublicResolverImportsStructuredPodcastEpisodePageWithPublisherChapters() throws {
        let metadata = #"{"type":"episode","code":"1891","title":"1891: We Need Memes!","src":"https://op3.dev/e/example/NA-1891-Final.mp3","duration":11215,"publishedAt":"2026-08-02","transcript":"https://mp3s.nashownotes.com/NA-1891-Captions.srt","chapters":"https://chapters.example.com/NA-1891-Chapters.json"}"#
        let encodedMetadata = metadata.replacingOccurrences(of: "\"", with: "&quot;")
        let page = """
        <!doctype html>
        <html><head><title>No Agenda 1891</title></head><body>
          <a data-play-metadata-value="\(encodedMetadata)">Play</a>
        </body></html>
        """
        let chapterJSON = """
        {"version":"1.2.0","chapters":[
          {"startTime":0,"title":"Show Open"},
          {"startTime":303.322,"title":"Press Malpractice"}
        ]}
        """
        let request = LinkResolutionRequest(
            id: "request-no-agenda-page",
            inputURL: "https://www.noagendashow.net/listen/1891",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "www.noagendashow.net" { return Data(page.utf8) }
            if url.host == "chapters.example.com" { return Data(chapterJSON.utf8) }
            throw URLError(.badURL)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "episode_page")
        XCTAssertEqual(result.selectedCandidate?.title, "1891: We Need Memes!")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 11_215_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://op3.dev/e/example/NA-1891-Final.mp3")
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks.first?.type, "application/srt")
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.chapters[1].startMs, 303_322)
    }

    func testPublicResolverUsesAppleLookupAudioURL() throws {
        let lookup = """
        {
          "resultCount": 3,
          "results": [
            {
              "wrapperType": "track",
              "kind": "podcast",
              "trackId": 123456,
              "collectionName": "Apple Show",
              "feedUrl": "https://feeds.example.com/apple-show.xml"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackId": 111,
              "trackName": "Different Episode",
              "episodeUrl": "https://cdn.example.com/wrong-episode.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackId": 999,
              "trackName": "Apple Episode",
              "collectionName": "Apple Show",
              "episodeUrl": "https://cdn.example.com/apple-episode.mp3"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Apple Episode</title>
              <guid>https://podcasts.apple.com/us/podcast/show/id123456?i=999</guid>
              <enclosure url="https://cdn.example.com/apple-episode.mp3" type="audio/mpeg" />
              <psc:chapters><psc:chapter start="0" title="Publisher Opening" /></psc:chapters>
            </item>
          </channel>
        </rss>
        """

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.absoluteString == "https://feeds.example.com/apple-show.xml" {
                return Data(feed.utf8)
            }
            XCTAssertTrue(url.absoluteString.contains("itunes.apple.com/lookup"))
            XCTAssertTrue(url.absoluteString.contains("id=123456"))
            XCTAssertTrue(url.absoluteString.contains("entity=podcastEpisode"))
            XCTAssertTrue(url.absoluteString.contains("limit=200"))
            return Data(lookup.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/apple-episode.mp3")
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.source, .podloveSimpleChapters)
    }

    func testPublicResolverAcceptsAppleLookupExtensionlessAudioURL() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "trackId": 999,
            "trackName": "Apple Episode",
            "collectionName": "Apple Show",
            "episodeUrl": "https://traffic.example.net/APPLEEPISODE123"
          }]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple-extensionless",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(lookup.utf8) }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://traffic.example.net/APPLEEPISODE123")
    }

    func testPublicResolverRecoversCanonicalFeedForExistingAppleEpisode() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let episodeURL = try XCTUnwrap(URL(string: "https://podcasts.apple.com/us/podcast/show/id123456?i=999"))
        let resolver = PublicPodcastLinkResolver(fetch: { url in
            XCTAssertTrue(url.absoluteString.contains("itunes.apple.com/lookup"))
            return Data(lookup.utf8)
        })

        XCTAssertEqual(
            try resolver.canonicalFeedURL(for: episodeURL)?.absoluteString,
            "https://feeds.example.com/apple-show.xml"
        )
    }

    func testPublicResolverFallsBackToApplePageStreamWhenLookupIsEmpty() throws {
        let html = #"""
        <html>
          <head><title>Apple Page Episode - Apple Podcasts</title></head>
          <body>
            <script>
              {"title":"Apple Page Episode","collectionName":"Apple Page Show","streamUrl":"https:\/\/traffic.example.net\/page-episode.mp3","duration":1971}
            </script>
          </body>
        </html>
        """#
        let request = LinkResolutionRequest(
            id: "request-apple-page",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.absoluteString.contains("itunes.apple.com/lookup") {
                return Data(#"{"resultCount":0,"results":[]}"#.utf8)
            }
            XCTAssertTrue(url.absoluteString.contains("podcasts.apple.com"))
            return Data(html.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Page Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Page Show")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 1_971_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://traffic.example.net/page-episode.mp3")
    }

    func testPublicResolverFallsBackToFeedWhenEpisodeIsOutsideAppleLookupWindow() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/wrong-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Requested Old Episode</title>
              <enclosure url="https://cdn.example.com/requested-old-episode.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-apple-feed-fallback",
            inputURL: "https://podcasts.apple.com/us/podcast/requested-old-episode/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "itunes.apple.com" {
                return Data(lookup.utf8)
            }
            XCTAssertEqual(url.absoluteString, "https://feeds.example.com/apple-show.xml")
            return Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Requested Old Episode")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/requested-old-episode.mp3")
    }

    func testPublicResolverUsesApplePageWhenShowSlugCannotIdentifyEpisodeInFeed() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 1528594034,
            "feedUrl": "https://feeds.example.com/hard-fork.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Hard Fork</title>
            <item>
              <title>OpenAI Models Go Rogue + Kimi K3 Freakout + A.I. Superforecasting</title>
              <enclosure url="https://cdn.example.com/feed-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/another.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let page = #"""
        <html>
          <head><title>OpenAI Models Go Rogue - Hard Fork - Apple Podcasts</title></head>
          <body>
            <script>
              {"title":"OpenAI Models Go Rogue + Kimi K3 Freakout + A.I. Superforecasting","streamUrl":"https:\/\/cdn.example.com\/apple-page-episode.mp3","duration":4094}
            </script>
          </body>
        </html>
        """#
        let request = LinkResolutionRequest(
            id: "request-apple-current-episode",
            inputURL: "https://podcasts.apple.com/us/podcast/hard-fork/id1528594034?i=1000778186885",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            switch url.host {
            case "itunes.apple.com":
                return Data(lookup.utf8)
            case "feeds.example.com":
                return Data(feed.utf8)
            case "podcasts.apple.com":
                return Data(page.utf8)
            default:
                XCTFail("Unexpected resolver URL: \(url)")
                return Data()
            }
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "apple_podcasts")
        XCTAssertEqual(result.selectedCandidate?.title, "OpenAI Models Go Rogue + Kimi K3 Freakout + A.I. Superforecasting")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 4_094_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/apple-page-episode.mp3")
    }

    func testAppleFeedFallbackNeverSelectsADifferentEpisode() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Newest Episode</title>
              <enclosure url="https://cdn.example.com/newest-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/another-episode.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-apple-no-wrong-fallback",
            inputURL: "https://podcasts.apple.com/us/podcast/requested-missing-episode/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            url.host == "itunes.apple.com" ? Data(lookup.utf8) : Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.failureReason, "rss_episode_ambiguous")
    }

    func testPublicResolverExplainsWhenSpotifyEpisodeHasNoAppleMatch() throws {
        let oEmbed = #"{"title":"Spotify Episode"}"#
        let request = LinkResolutionRequest(
            id: "request-spotify",
            inputURL: "https://open.spotify.com/episode/abc123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                return Data(oEmbed.utf8)
            }
            if url.host?.contains("spotify.com") == true {
                return Data()
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            return Data(#"{"resultCount":0,"results":[]}"#.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.candidates.first?.title, "Spotify Episode")
        XCTAssertEqual(result.failureReason, "spotify_episode_not_found_on_apple")
    }

    func testPublicResolverRequiresASpecificSpotifyEpisodeLink() throws {
        let request = LinkResolutionRequest(
            id: "request-spotify-show",
            inputURL: "https://open.spotify.com/show/show123",
            sourceSurface: "share_extension",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in
            XCTFail("A Spotify show link should be rejected before network resolution")
            return Data()
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.originalLink.provider, "spotify")
        XCTAssertEqual(result.failureReason, "spotify_specific_episode_required")
    }

    func testPublicResolverNormalizesSpotifyEpisodeToExactAppleMatch() throws {
        let oEmbed = #"{"title":"The Shared Episode!"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "A Different Episode",
              "collectionName": "Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "The Shared Episode",
              "collectionName": "Shared Show",
              "trackViewUrl": "https://podcasts.apple.com/us/podcast/shared-show/id123?i=456",
              "episodeUrl": "https://cdn.example.com/shared.mp3",
              "trackTimeMillis": 123000,
              "releaseDate": "2026-07-01T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-apple-match",
            inputURL: "https://open.spotify.com/episode/shared123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                XCTAssertEqual(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                    request.inputURL
                )
                return Data(oEmbed.utf8)
            }
            if url.host?.contains("spotify.com") == true {
                return Data()
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "entity" })?.value, "podcastEpisode")
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "spotify")
        XCTAssertEqual(result.selectedCandidate?.sourceLink.provider, "apple_podcasts")
        XCTAssertEqual(result.selectedCandidate?.title, "The Shared Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Shared Show")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 123_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/shared.mp3")
    }

    func testSpotifyMatchedAppleEpisodeResolvesCanonicalFeed() throws {
        let oEmbed = #"{"title":"The Shared Episode!"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "A Different Episode",
              "collectionName": "Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "The Shared Episode",
              "collectionName": "Shared Show",
              "trackViewUrl": "https://podcasts.apple.com/us/podcast/shared-show/id123?i=456",
              "episodeUrl": "https://cdn.example.com/shared.mp3",
              "trackTimeMillis": 123000,
              "releaseDate": "2026-07-01T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-apple-match",
            inputURL: "https://open.spotify.com/episode/shared123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let feed = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                XCTAssertEqual(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                    request.inputURL
                )
                return Data(oEmbed.utf8)
            }
            if url.host?.contains("spotify.com") == true {
                return Data()
            }
            if url.path == "/lookup" {
                return Data(#"{"results":[{"feedUrl":"https://example.com/show.rss"}]}"#.utf8)
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "entity" })?.value, "podcastEpisode")
            return Data(appleSearch.utf8)
        }).canonicalFeedURL(for: try XCTUnwrap(URL(string: request.inputURL)))

        XCTAssertEqual(feed?.absoluteString, "https://example.com/show.rss")
    }

    func testPublicResolverDoesNotGuessBetweenAmbiguousSpotifyAppleMatches() throws {
        let oEmbed = #"{"title":"Trailer"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "trackName": "Trailer",
              "collectionName": "Show One",
              "episodeUrl": "https://cdn.example.com/show-one.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "trackName": "Trailer",
              "collectionName": "Show Two",
              "episodeUrl": "https://cdn.example.com/show-two.mp3"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-ambiguous",
            inputURL: "https://open.spotify.com/episode/trailer123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" { return Data(oEmbed.utf8) }
            if url.host?.contains("spotify.com") == true { return Data() }
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.failureReason, "spotify_episode_match_ambiguous")
    }

    func testPublicResolverUsesShowDateAndDurationToDisambiguateSpotifyEpisode() throws {
        let oEmbed = """
        {
          "title": "A Shared Episode",
          "showTitle": "The Correct Show",
          "releaseDate": "2026-07-02T00:00:00Z",
          "durationMs": 3600000
        }
        """
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "trackName": "A Shared Episode",
              "collectionName": "The Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3",
              "trackTimeMillis": 2400000,
              "releaseDate": "2025-01-01T00:00:00Z"
            },
            {
              "wrapperType": "podcastEpisode",
              "trackName": "A Shared Episode",
              "collectionName": "The Correct Show",
              "trackViewUrl": "https://podcasts.apple.com/correct",
              "episodeUrl": "https://cdn.example.com/correct.mp3",
              "trackTimeMillis": 3601000,
              "releaseDate": "2026-07-02T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-evidence",
            inputURL: "https://open.spotify.com/episode/evidence123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" { return Data(oEmbed.utf8) }
            if url.host?.contains("spotify.com") == true { return Data() }
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.showTitle, "The Correct Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/correct.mp3")
        XCTAssertGreaterThanOrEqual(result.selectedCandidate?.confidence ?? 0, 0.78)
    }

    func testPublicResolverRetriesSpotifyEpisodeNumberTitleWithoutPrefix() throws {
        let oEmbed = #"{"title":"895: Label Maker!"}"#
        let spotifyEmbedPage = #"""
        <html><body>
          <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"episode","name":"895: Label Maker!","title":"895: Label Maker!","subtitle":"This American Life","releaseDate":{"isoString":"2026-08-17T00:00:00Z"},"duration":3464385}}}}}}</script>
        </body></html>
        """#
        let appleMatch = #"""
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "kind": "podcast-episode",
            "trackId": 1000783492833,
            "trackName": "Label Maker!",
            "collectionName": "This American Life",
            "trackViewUrl": "https://podcasts.apple.com/us/podcast/this-american-life/id201671138?i=1000783492833",
            "episodeUrl": "https://cdn.example.com/label-maker.mp3",
            "trackTimeMillis": 3576000,
            "releaseDate": "2026-08-17T00:00:00Z"
          }]
        }
        """#
        let request = LinkResolutionRequest(
            id: "request-spotify-numbered-title",
            inputURL: "https://open.spotify.com/episode/labelmaker123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                return Data(oEmbed.utf8)
            }
            if url.path == "/embed/episode/labelmaker123" {
                return Data(spotifyEmbedPage.utf8)
            }
            let searchTerm = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "term" })?
                .value
            switch searchTerm {
            case "895: Label Maker!":
                return Data(#"{"resultCount":0,"results":[]}"#.utf8)
            case "Label Maker!":
                return Data(appleMatch.utf8)
            default:
                XCTFail("Unexpected resolver URL: \(url)")
                return Data()
            }
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Label Maker!")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "This American Life")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/label-maker.mp3")
        XCTAssertGreaterThanOrEqual(result.selectedCandidate?.confidence ?? 0, 0.78)
    }

    func testPublicResolverDoesNotAutoSelectExactTitleFromConflictingShow() throws {
        let oEmbed = #"{"title":"Shared Episode","showTitle":"Expected Show"}"#
        let appleSearch = #"""
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "trackName": "Shared Episode",
            "collectionName": "Different Show",
            "episodeUrl": "https://cdn.example.com/different-show.mp3"
          }]
        }
        """#
        let request = LinkResolutionRequest(
            id: "request-spotify-conflicting-show",
            inputURL: "https://open.spotify.com/episode/conflict123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" { return Data(oEmbed.utf8) }
            if url.host?.contains("spotify.com") == true { return Data() }
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.candidates.map(\.showTitle), ["Different Show"])
        XCTAssertEqual(result.failureReason, "spotify_episode_match_ambiguous")
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

private actor AcquiredWindowTranscriptionClient: SourceTranscriptionClient {
    private let windowURL: URL
    private var acquisitionCount = 0
    private var acquiredCount = 0
    private var originalCount = 0
    private var receivedURL: URL?

    init(windowURL: URL) { self.windowURL = windowURL }

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("unexpected_full_source_transcription")
    }

    func acquireSourceAudioWindow(
        url: URL, itemId: String, anchorMediaTimeMs: Int, durationMs: Int?,
        windowBeforeMs: Int, windowAfterMs: Int
    ) async throws -> SourceAudioWindowAcquisition {
        acquisitionCount += 1
        guard anchorMediaTimeMs == 123_000, windowBeforeMs == 90_000, windowAfterMs == 120_000 else {
            throw SessionKitError.persistenceFailed("wrong_acquisition_bounds")
        }
        return SourceAudioWindowAcquisition(
            localAudioURL: windowURL, sourceStartMs: 110_000, sourceEndMs: 134_000,
            provenance: .sourceWindowReference
        )
    }

    func transcribeAcquiredSourceAudioWindow(
        _ acquisition: SourceAudioWindowAcquisition, itemId: String, durationMs: Int?
    ) async throws -> TranscriptTimeline {
        acquiredCount += 1
        receivedURL = acquisition.localAudioURL
        guard acquisition.localAudioURL == windowURL,
              acquisition.sourceStartMs == 110_000,
              acquisition.sourceEndMs == 134_000,
              FileManager.default.fileExists(atPath: windowURL.path) else {
            throw SessionKitError.persistenceFailed("acquired_window_changed_before_asr")
        }
        return TranscriptTimeline(segments: [
            .init(id: "before", startMs: 118_000, endMs: 122_000, text: "Before the note."),
            .init(id: "at", startMs: 122_000, endMs: 124_000, text: "At the note."),
            .init(id: "after", startMs: 124_000, endMs: 128_000, text: "After the note.")
        ], chapters: [], durationMs: durationMs)
    }

    func transcribeSourceAudioWindow(
        url: URL, itemId: String, anchorMediaTimeMs: Int, durationMs: Int?,
        windowBeforeMs: Int, windowAfterMs: Int
    ) async throws -> TranscriptTimeline {
        originalCount += 1
        throw SessionKitError.persistenceFailed("unexpected_second_source_fetch")
    }

    func calls() -> (acquisitions: Int, acquiredTranscriptions: Int, originalURLTranscriptions: Int, acquiredURL: URL?) {
        (acquisitionCount, acquiredCount, originalCount, receivedURL)
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
