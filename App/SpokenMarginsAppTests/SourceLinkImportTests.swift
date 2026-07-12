import XCTest
import SessionKit
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SourceLinkImportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
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
    }

    func testNativeAudioInterjectionRequestsOneMinuteSourceWindowContext() async throws {
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
                MediaTimelineSegment(id: "window-before", startMs: 63_000, endMs: 122_000, text: "Minute before."),
                MediaTimelineSegment(id: "window-current", startMs: 122_000, endMs: 124_000, text: "Interjection context."),
                MediaTimelineSegment(id: "window-after", startMs: 124_000, endMs: 183_000, text: "Minute after.")
            ],
            chapters: [],
            durationMs: 300_000
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: transcriber
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
        XCTAssertEqual(request.windowBeforeMs, 60_000)
        XCTAssertEqual(request.windowAfterMs, 60_000)
        XCTAssertEqual(request.durationMs, 300_000)
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorBefore, "Minute before. Interjection context.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorAfter, "Minute after.")
        XCTAssertEqual(model.diagnostics["sourceWindowContextProvenance:ij-001"], "speech_window")
    }

    func testStoredTranscriptWindowIsUsedOnlyWhenItCoversPodcastAnchor() throws {
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "before", startMs: 50_000, endMs: 100_000, text: "Before."),
                MediaTimelineSegment(id: "anchor", startMs: 100_000, endMs: 140_000, text: "At anchor."),
                MediaTimelineSegment(id: "after", startMs: 140_000, endMs: 200_000, text: "After."),
                MediaTimelineSegment(id: "far", startMs: 400_000, endMs: 450_000, text: "Far away.")
            ],
            chapters: [],
            durationMs: 600_000
        )

        let window = try XCTUnwrap(Gate1AppModel.sourceContextWindow(from: timeline, anchorMediaTimeMs: 123_000))

        XCTAssertEqual(window.segments.map(\.id), ["before", "anchor", "after"])
        XCTAssertNil(Gate1AppModel.sourceContextWindow(from: timeline, anchorMediaTimeMs: 300_000))
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

    func testIncomingPayloadIsRetainedAfterUnsupportedImport() throws {
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

        XCTAssertEqual(model.diagnostics["lastSourceLinkStatus"], LinkResolutionStatus.unsupported.rawValue)
        XCTAssertEqual(model.diagnostics["lastSourceLinkPayloadCleanup"], "retained_after_failed_import")
        XCTAssertEqual(
            model.lastError,
            "This looks like a Spotify-only episode. Spoken Margins could not find a public audio file for it yet."
        )
        XCTAssertEqual(try store.handoff(payloadID: handoff.id), handoff)
    }

    func testForegroundActivationImportsSavedSharePayloadIntoLibraryWithoutAutoplay() async throws {
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
        model.screen = .home

        model.handleAppBecameActive()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.snapshot.status, .idle)
        XCTAssertEqual(model.selectedItem.title, "Shared Episode")
        XCTAssertTrue(model.libraryItems.contains { $0.title == "Shared Episode" })
        XCTAssertEqual(resolver.resolveCount, 1)
        XCTAssertThrowsError(try store.handoff(payloadID: sharedHandoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(sharedHandoff.id))
        }
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
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.selectedItem.title, "Pending Episode")
        XCTAssertEqual(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"], "deleted_after_import")
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
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Example Show</title>
            <item>
              <title>Episode One</title>
              <guid>episode-one</guid>
              <pubDate>Fri, 19 Jun 2026 12:00:00 GMT</pubDate>
              <itunes:duration>00:30:00</itunes:duration>
              <enclosure url="https://cdn.example.com/episode-one.mp3" type="audio/mpeg" length="1" />
              <podcast:transcript url="https://cdn.example.com/episode-one.vtt" type="text/vtt" language="en" rel="captions" />
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

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(feed.utf8) }).resolve(request)

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
    }

    func testPublicResolverUsesAppleLookupAudioURL() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "trackName": "Apple Episode",
            "collectionName": "Apple Show",
            "episodeUrl": "https://cdn.example.com/apple-episode.mp3"
          }]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            XCTAssertTrue(url.absoluteString.contains("itunes.apple.com/lookup"))
            return Data(lookup.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/apple-episode.mp3")
    }

    func testPublicResolverAcceptsAppleLookupExtensionlessAudioURL() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
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

    func testPublicResolverFallsBackForSpotifyExclusive() throws {
        let html = #"<html><head><meta property="og:title" content="Spotify Episode"></head></html>"#
        let request = LinkResolutionRequest(
            id: "request-spotify",
            inputURL: "https://open.spotify.com/episode/abc123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(html.utf8) }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.candidates.first?.title, "Spotify Episode")
        XCTAssertEqual(result.failureReason, "spotify_audio_requires_provider_playback")
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
            durationMs: 300_000,
            playbackRate: 1,
            anchorConfidence: .mediaTime
        )
    }
}

private actor RecordingSourceWindowTranscriptionClient: SourceTranscriptionClient {
    struct WindowRequest: Sendable {
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
}
