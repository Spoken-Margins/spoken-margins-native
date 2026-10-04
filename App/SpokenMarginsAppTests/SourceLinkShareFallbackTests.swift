import XCTest
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #223: a link shared as a bare URL from another app (the Substack app shares a post that way) is added as an
/// article, like a Safari share or the Link field. It used to be quarantined because this path only tried podcasts.
@MainActor
final class SourceLinkShareFallbackTests: XCTestCase {
    nonisolated private static let postURL = "https://garymarcus.substack.com/p/breaking-ai-agent-incident-toll-has"
    nonisolated private static let postTitle = "BREAKING: AI agent incident toll has risen to tens of thousands"
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSharedSubstackPostBecomesAnArticleInsteadOfBeingQuarantined() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(id: "source-link-substack-post", inputURL: Self.postURL, sourceSurface: "share_sheet", startSession: true)
        try store.save(handoff)
        let extractor = RecordedPageExtractor(.success(try AppOwnedReadablePageExtractor.handoff(from: [
            "text": "# \(Self.postTitle)\n\nThe number of reported incidents involving AI agents keeps climbing.",
            "metadata": ["extractor": "defuddle"],
            "source": ["url": Self.postURL, "title": Self.postTitle, "author": "Gary Marcus"]
        ])))
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: { try SourceLinkShareFallbackTests.substackPostAndFeed($0) }),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        model.readablePageExtractor = extractor
        model.sharedLinkVoiceover.fetchPage = { _ in throw URLError(.notConnectedToInternet) } // stay offline (#810)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("shared post import") {
            model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"] != nil
        }

        XCTAssertEqual(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"], "imported")
        XCTAssertEqual(model.diagnostics["lastSourceLinkArticleFallback"], "defuddle")
        XCTAssertEqual(extractor.requested, [URL(string: Self.postURL)!])
        XCTAssertEqual(try store.failedHandoffs(), [])
        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(handoff.id))
        }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == Self.postTitle })
        XCTAssertFalse(row.hasNativeAudio)
        XCTAssertEqual(model.screen, .home)
        model.openItem(id: row.id)
        XCTAssertTrue(model.selectedItem.text.contains("reported incidents involving AI agents"), model.selectedItem.text)
    }

    /// #810: the shared post has the publisher's own voiceover. The article keeps it as its `publisher_audio`
    /// record, as a followed post does, after one fetch of the post page. Before, nothing looked.
    func testSharedSubstackPostWithAVoiceoverKeepsThePublisherAudio() async throws {
        let (model, store, databaseURL) = try makeVoiceoverShareModel()
        let fetched = FetchedPages()
        model.sharedLinkVoiceover.fetchPage = { url in
            fetched.append(url)
            return (Self.voiceoverPage(canonicalURL: Self.postURL), URL(string: Self.postURL)!)
        }

        model.importPendingSourceLinkHandoffs()
        let database = try SQLiteSessionStore(path: databaseURL.path)
        var itemId: String?
        try await waitFor("voiceover record") {
            itemId = model.libraryItems.first { $0.title == Self.postTitle }?.id
            return itemId.flatMap { try? database.loadPublisherAudio(itemId: $0) } != nil
        }

        let id = try XCTUnwrap(itemId)
        XCTAssertEqual(try database.loadPublisherAudio(itemId: id)?.audioURL, "https://recordings.example/voiceover.mp3")
        XCTAssertEqual(try database.loadPublisherAudio(itemId: id)?.durationMs, 752_875)
        XCTAssertEqual(try database.loadPublisherAudio(itemId: id)?.detectedFrom, "substack_post_voiceover")
        XCTAssertEqual(fetched.urls, [URL(string: Self.postURL)!], "the page is fetched once")
        XCTAssertEqual(try store.failedHandoffs(), [])
        XCTAssertEqual(try database.loadItem(id: id).mediaType, "text", "it is still an article")
    }

    /// The post page can't be fetched: the article is imported as before, with no record and a diagnostic.
    func testSharedSubstackPostWhosePageFailsIsStillAnArticle() async throws {
        let (model, store, databaseURL) = try makeVoiceoverShareModel()
        model.sharedLinkVoiceover.fetchPage = { _ in throw URLError(.notConnectedToInternet) }

        model.importPendingSourceLinkHandoffs()
        try await waitFor("voiceover diagnostic") {
            model.diagnostics["sharedLinkVoiceover"]?.contains("failed:") == true
        }

        let row = try XCTUnwrap(model.libraryItems.first { $0.title == Self.postTitle })
        XCTAssertNil(try SQLiteSessionStore(path: databaseURL.path).loadPublisherAudio(itemId: row.id))
        XCTAssertEqual(try store.failedHandoffs(), [])
    }

    /// The page loads and has no audio, but the extractor finds no article text (a paywall stub, say).
    func testUnreadableSharedPageIsStillQuarantinedNamingTheExtractorFailure() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(id: "source-link-unreadable", inputURL: Self.postURL, sourceSurface: "share_sheet", startSession: true)
        try store.save(handoff)
        let extractor = RecordedPageExtractor(.failure(ReadablePageExtractionError.invalidResult))
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: { try SourceLinkShareFallbackTests.substackPostAndFeed($0) }),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let itemsBefore = model.libraryItems.map(\.id)
        model.readablePageExtractor = extractor

        model.importPendingSourceLinkHandoffs()
        try await waitFor("unreadable share quarantine") {
            (try? store.failedHandoffs().count) == 1
        }

        XCTAssertEqual(extractor.requested, [URL(string: Self.postURL)!])
        let diagnostic = model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"] ?? "none"
        XCTAssertTrue(diagnostic.hasPrefix("quarantined:"), diagnostic)
        XCTAssertTrue(diagnostic.contains("No readable article text was found."), diagnostic)
        XCTAssertEqual(model.diagnostics["lastSourceLinkArticleFallback"], "failed:No readable article text was found.")
        let failed = try XCTUnwrap(store.failedHandoffs().first)
        XCTAssertEqual(failed.handoff, handoff)
        XCTAssertTrue(failed.reason.contains("No readable article text was found."), failed.reason)
        XCTAssertEqual(model.libraryItems.map(\.id), itemsBefore)
    }

    /// A 404 fails in the podcast resolver's own fetch, before any article reading, and is quarantined as before.
    func testMissingSharedPageIsQuarantinedWithoutReadingIt() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(id: "source-link-gone", inputURL: "https://garymarcus.substack.com/p/deleted", sourceSurface: "share_sheet", startSession: true)
        try store.save(handoff)
        let extractor = RecordedPageExtractor(.failure(ReadablePageExtractionError.invalidResult))
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: { _ in throw URLError(.badServerResponse) }),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let itemsBefore = model.libraryItems.map(\.id)
        model.readablePageExtractor = extractor

        model.importPendingSourceLinkHandoffs()
        try await waitFor("missing page quarantine") {
            (try? store.failedHandoffs().count) == 1
        }

        XCTAssertEqual(extractor.requested, [])
        XCTAssertTrue(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"]?.hasPrefix("quarantined:") == true)
        XCTAssertEqual(try store.failedHandoffs().first?.handoff, handoff)
        XCTAssertEqual(model.libraryItems.map(\.id), itemsBefore)
    }

    /// An excerpt of the post page and publication feed research/B2 recorded: the page links its feed, and the
    /// feed lists the post with its cover image as an `image/jpeg` enclosure. Anything else is offline.
    nonisolated private static func substackPostAndFeed(_ url: URL) throws -> Data {
        switch url.absoluteString {
        case postURL:
            return Data("""
            <!DOCTYPE html><html lang="en"><head><meta charset="utf-8" />
            <title data-rh="true">\(postTitle)</title>
            <meta data-rh="true" property="og:type" content="article"/><meta data-rh="true" property="og:title" content="\(postTitle)"/>
            <link rel="alternate" type="application/rss+xml" href="/feed" title="Marcus on AI"/>
            </head><body><article><h1>\(postTitle)</h1></article></body></html>
            """.utf8)
        case "https://garymarcus.substack.com/feed":
            return Data("""
            <?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel><title><![CDATA[Marcus on AI]]></title><link>https://garymarcus.substack.com</link>
            <item><title><![CDATA[\(postTitle)]]></title><link>\(postURL)</link><guid isPermaLink="false">\(postURL)</guid><dc:creator><![CDATA[Gary Marcus]]></dc:creator><enclosure url="https://substack-post-media.s3.amazonaws.com/public/images/4c9151fe-ff2a-4d88-8a63-fcd6da44355b_1725x1589.png" length="0" type="image/jpeg"/></item>
            </channel></rss>
            """.utf8)
        default:
            throw URLError(.notConnectedToInternet)
        }
    }

    private func makeVoiceoverShareModel() throws -> (Gate1AppModel, SourceLinkHandoffStore, URL) {
        let store = makePayloadStore()
        try store.save(SourceLinkHandoff(id: "source-link-voiceover-post", inputURL: Self.postURL, sourceSurface: "share_sheet", startSession: false))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-share-voiceover-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: { try SourceLinkShareFallbackTests.substackPostAndFeed($0) }),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.readablePageExtractor = RecordedPageExtractor(.success(try AppOwnedReadablePageExtractor.handoff(from: [
            "text": "# \(Self.postTitle)\n\nThe number of reported incidents involving AI agents keeps climbing.",
            "metadata": ["extractor": "defuddle"],
            "source": ["url": Self.postURL, "title": Self.postTitle, "author": "Gary Marcus"]
        ])))
        return (model, store, databaseURL)
    }

    /// The `window._preloads` shape of Contracts/fixtures/feeds/substack-voiceover-page.html, for this post.
    nonisolated private static func voiceoverPage(canonicalURL: String) -> String {
        #"<html><head><script>window._preloads = JSON.parse("{\"post\":{\"type\":\"newsletter\",\"has_voiceover\":true,\"canonical_url\":\""#
            + canonicalURL
            + #"\",\"id\":1,\"audio_items\":[{\"post_id\":1,\"voice_id\":\"voiceover\",\"audio_url\":\"https://recordings.example/voiceover.mp3\",\"type\":\"voiceover\",\"status\":\"completed\",\"duration\":752.8751}]}}");</script></head><body></body></html>"#
    }

    private func makePayloadStore() -> SourceLinkHandoffStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-share-fallback-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return SourceLinkHandoffStore(baseDirectory: directory)
    }

    private func waitFor(_ description: String, timeoutNanoseconds: UInt64 = 2_000_000_000, condition: () -> Bool) async throws {
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            elapsed += 10_000_000
        }
        XCTFail("Timed out waiting for \(description).")
    }
}

/// The pages the voiceover lookup asked for.
private final class FetchedPages: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [URL] = []

    func append(_ url: URL) { lock.withLock { requested.append(url) } }
    var urls: [URL] { lock.withLock { requested } }
}

/// Stands in for the web view: WebKit loads pages outside URLProtocol, so the page's text comes from the payload
/// the bundled extractor script returns, mapped by the app's own `AppOwnedReadablePageExtractor.handoff(from:)`.
@MainActor
private final class RecordedPageExtractor: ReadablePageExtracting {
    private let outcome: Result<BrowserTextHandoff, Error>
    private(set) var requested: [URL] = []
    private(set) var lastExtractor: String?
    private(set) var contactedHosts: [String] = []

    init(_ outcome: Result<BrowserTextHandoff, Error>) {
        self.outcome = outcome
    }

    func extract(url: URL) async throws -> BrowserTextHandoff {
        requested.append(url)
        contactedHosts = [url.host ?? ""]
        lastExtractor = nil
        let handoff = try outcome.get()
        lastExtractor = "defuddle"
        return handoff
    }
}
