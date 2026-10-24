import XCTest
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
import WebKit
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
        let extractor = URLProtocolPageExtractor()
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: RecordedSubstackURLProtocol.fetch),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        model.readablePageExtractor = extractor
        model.sharedLinkVoiceover.fetchPage = { _ in throw URLError(.notConnectedToInternet) } // stay offline (#810)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("shared post import") {
            model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"] != nil && !model.isImportingPendingSourceLinkHandoffs
        }

        XCTAssertEqual(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"], "imported")
        XCTAssertNotNil(model.diagnostics["lastSourceLinkArticleFallback"])
        XCTAssertEqual(extractor.requested, [URL(string: Self.postURL)!])
        XCTAssertEqual(try store.failedHandoffs(), [])
        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(handoff.id))
        }
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == Self.postTitle })
        XCTAssertEqual(row.mediaType, "text")
        XCTAssertEqual(row.sourceReference, Self.postURL)
        XCTAssertFalse(row.hasNativeAudio)
        XCTAssertEqual(model.screen, .home)
        model.openItem(id: row.id)
        XCTAssertEqual(model.selectedItem.externalReference, Self.postURL)
        XCTAssertTrue(model.selectedItem.text.contains("controlled article body"), model.selectedItem.text)
    }

    /// #810: the shared post has the publisher's own voiceover. The article keeps it as its `publisher_audio`
    /// record, as a followed post does. Before, nothing looked. The voiceover lookup reads the post page the
    /// link resolver already fetched: resolution and the voiceover ask for the post page once between them
    /// (Codex audit on 749fc07). The web view that reads the article loads the page on its own, as before.
    func testSharedSubstackPostWithAVoiceoverKeepsThePublisherAudio() async throws {
        let requests = RequestedURLs()
        let (model, store, databaseURL) = try makeVoiceoverShareModel(requests: requests, postPageHasVoiceover: true)

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
        XCTAssertEqual(requests.urls.filter { $0.absoluteString == Self.postURL }.count, 1, "post page requests: \(requests.urls)")
        XCTAssertEqual(try store.failedHandoffs(), [])
        XCTAssertEqual(try database.loadItem(id: id).mediaType, "text", "it is still an article")
    }

    /// #810: a page clipped from Safari imports from its own text, so clipping works in airplane mode. The voiceover
    /// lookup comes after, and fails quietly offline. Opening the article once there is a connection finds it.
    func testClippedPageImportsOfflineAndFindsItsVoiceoverWhenOpenedOnline() async throws {
        let (model, _, databaseURL) = try makeVoiceoverShareModel(requests: RequestedURLs(), postPageHasVoiceover: false)
        var continuation = BrowserTextContinuation()
        continuation.startSession = false
        let clip = BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: Self.postURL, title: Self.postTitle),
            text: "# \(Self.postTitle)\n\nThe number of reported incidents involving AI agents keeps climbing.",
            requestedContinuation: continuation
        )

        XCTAssertTrue(model.importClippedPage(clip))
        try await waitFor("offline lookup") { model.diagnostics["sharedLinkVoiceover"]?.contains(": failed:") == true }
        let database = try SQLiteSessionStore(path: databaseURL.path)
        let id = try XCTUnwrap(model.libraryItems.first { $0.title == Self.postTitle }?.id, "the clip is imported with no network")
        XCTAssertNil(try database.loadPublisherAudio(itemId: id))

        model.sharedLinkVoiceover.fetchPage = { url in
            (html: "<html><head>" + SourceLinkShareFallbackTests.preloadsScript(canonicalURL: Self.postURL) + "</head></html>", finalURL: url)
        }
        model.openItem(id: id)
        try await waitFor("voiceover record") { (try? database.loadPublisherAudio(itemId: id)) != nil }
        XCTAssertEqual(try database.loadPublisherAudio(itemId: id)?.audioURL, "https://recordings.example/voiceover.mp3")
    }

    /// A clip made while something is in Now Playing opens its item (#1437), and opening looks for a voiceover
    /// too. The clip and the open share one lookup: the post page is fetched once (Claude audit on 34af58c).
    func testClipDuringPlaybackFetchesThePostPageOnce() async throws {
        let requests = RequestedURLs()
        let (model, _, _) = try makeVoiceoverShareModel(requests: requests, postPageHasVoiceover: false)
        model.sharedLinkVoiceover.fetchPage = { url in
            requests.append(url)
            return (html: "<html><head></head></html>", finalURL: url)
        }
        let playingID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: playingID)
        model.pause()
        XCTAssertTrue(model.hasActiveSession)
        let clip = BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: Self.postURL, title: Self.postTitle),
            text: "# \(Self.postTitle)\n\nThe number of reported incidents involving AI agents keeps climbing."
        )

        XCTAssertTrue(model.importClippedPage(clip))
        XCTAssertEqual(model.selectedItem.title, Self.postTitle, "the clip opens its item, as #1437 asks")
        try await waitFor("voiceover lookup") { model.diagnostics["sharedLinkVoiceover"]?.contains(": none:") == true }
        try await Task.sleep(nanoseconds: 500_000_000) // room for a second lookup, had one started
        XCTAssertEqual(requests.urls.filter { $0.absoluteString == Self.postURL }.count, 1, "post page requests: \(requests.urls)")
        XCTAssertEqual(model.snapshot.itemId, playingID, "Now Playing is untouched")
    }

    /// The post page has no voiceover: the article is imported as before, with no record, and the lookup
    /// doesn't fetch the page a second time to find that out.
    func testSharedSubstackPostWithoutAVoiceoverIsStillAnArticle() async throws {
        let requests = RequestedURLs()
        let (model, store, databaseURL) = try makeVoiceoverShareModel(requests: requests, postPageHasVoiceover: false)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("voiceover diagnostic") {
            model.diagnostics["sharedLinkVoiceover"]?.hasSuffix(": none:no_preloads") == true
        }

        let row = try XCTUnwrap(model.libraryItems.first { $0.title == Self.postTitle })
        XCTAssertNil(try SQLiteSessionStore(path: databaseURL.path).loadPublisherAudio(itemId: row.id))
        XCTAssertEqual(requests.urls.filter { $0.absoluteString == Self.postURL }.count, 1, "post page requests: \(requests.urls)")
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
            (try? store.failedHandoffs().count) == 1 && !model.isImportingPendingSourceLinkHandoffs
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

    /// Both the podcast fetch and the extractor see HTTP 404; quarantine keeps the extractor's specific reason.
    func testMissingSharedPageIsQuarantinedNamingTheExtractorHTTPStatus() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(id: "source-link-gone", inputURL: "https://garymarcus.substack.com/p/deleted", sourceSurface: "share_sheet", startSession: true)
        try store.save(handoff)
        let extractor = URLProtocolPageExtractor()
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: RecordedSubstackURLProtocol.fetch),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let itemsBefore = model.libraryItems.map(\.id)
        model.readablePageExtractor = extractor

        model.importPendingSourceLinkHandoffs()
        try await waitFor("missing page quarantine") {
            (try? store.failedHandoffs().count) == 1 && !model.isImportingPendingSourceLinkHandoffs
        }

        XCTAssertEqual(extractor.requested, [URL(string: handoff.inputURL)!])
        let diagnostic = model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"] ?? "none"
        XCTAssertTrue(diagnostic.hasPrefix("quarantined:"), diagnostic)
        XCTAssertTrue(diagnostic.contains("HTTP 404"), diagnostic)
        XCTAssertEqual(model.diagnostics["lastSourceLinkArticleFallback"], "failed:The site answered with HTTP 404 instead of the article.")
        XCTAssertEqual(try store.failedHandoffs().first?.handoff, handoff)
        XCTAssertTrue(try XCTUnwrap(store.failedHandoffs().first).reason.contains("HTTP 404"))
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

    /// `requests` records every page the share asks for, from the link resolver and the voiceover lookup alike.
    private func makeVoiceoverShareModel(requests: RequestedURLs, postPageHasVoiceover: Bool) throws -> (Gate1AppModel, SourceLinkHandoffStore, URL) {
        let store = makePayloadStore()
        try store.save(SourceLinkHandoff(id: "source-link-voiceover-post", inputURL: Self.postURL, sourceSurface: "share_sheet", startSession: false))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-share-voiceover-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let model = Gate1AppModel(
            sourceLinkResolver: PublicPodcastLinkResolver(fetch: { url in
                requests.append(url)
                let page = try SourceLinkShareFallbackTests.substackPostAndFeed(url)
                guard postPageHasVoiceover, url.absoluteString == Self.postURL else { return page }
                return Data(String(decoding: page, as: UTF8.self)
                    .replacingOccurrences(of: "</head>", with: Self.preloadsScript(canonicalURL: Self.postURL) + "</head>").utf8)
            }),
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.sharedLinkVoiceover.fetchPage = { url in
            requests.append(url)
            throw URLError(.notConnectedToInternet)
        }
        model.readablePageExtractor = RecordedPageExtractor(.success(try AppOwnedReadablePageExtractor.handoff(from: [
            "text": "# \(Self.postTitle)\n\nThe number of reported incidents involving AI agents keeps climbing.",
            "metadata": ["extractor": "defuddle"],
            "source": ["url": Self.postURL, "title": Self.postTitle, "author": "Gary Marcus"]
        ])))
        return (model, store, databaseURL)
    }

    /// The `window._preloads` shape of Contracts/fixtures/feeds/substack-voiceover-page.html, for this post.
    nonisolated private static func preloadsScript(canonicalURL: String) -> String {
        #"<script>window._preloads = JSON.parse("{\"post\":{\"type\":\"newsletter\",\"has_voiceover\":true,\"canonical_url\":\""#
            + canonicalURL
            + #"\",\"id\":1,\"audio_items\":[{\"post_id\":1,\"voice_id\":\"voiceover\",\"audio_url\":\"https://recordings.example/voiceover.mp3\",\"type\":\"voiceover\",\"status\":\"completed\",\"duration\":752.8751}]}}");</script>"#
    }

    private func makePayloadStore() -> SourceLinkHandoffStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-share-fallback-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return SourceLinkHandoffStore(baseDirectory: directory)
    }

    /// Some of these shares go through real WebKit extraction (#1049). WebKit's own
    /// processes took 24 s to launch in a full app-plan run (#1413), so the
    /// default allows 60 s; a passing share returns as soon as it lands.
    private func waitFor(_ description: String, timeoutNanoseconds: UInt64 = 60_000_000_000, condition: () -> Bool) async throws {
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            elapsed += 10_000_000
        }
        XCTFail("Timed out waiting for \(description).")
    }
}

/// The pages a share asked for.
private final class RequestedURLs: @unchecked Sendable {
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

/// WebKit's HTTPS requests bypass URLProtocol. Fetch the fixture through URLProtocol, then run the
/// bundled production capture script on its DOM. No canned title/body is returned to the model.
@MainActor
private final class URLProtocolPageExtractor: NSObject, ReadablePageExtracting, WKNavigationDelegate {
    private(set) var requested: [URL] = []
    private(set) var lastExtractor: String?
    private(set) var contactedHosts: [String] = []
    private var webView: WKWebView?
    private var documentURL: URL?
    private var continuation: CheckedContinuation<BrowserTextHandoff, Error>?

    func extract(url: URL) async throws -> BrowserTextHandoff {
        requested.append(url)
        contactedHosts = [url.host ?? ""]
        let (data, response) = try await RecordedSubstackURLProtocol.session.data(from: url)
        documentURL = response.url ?? url
        if let status = AppOwnedReadablePageExtractor.failingHTTPStatus(response) {
            throw ReadablePageExtractionError.httpStatus(status)
        }
        let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "browserTextCapture", withExtension: "js"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: try String(contentsOf: scriptURL, encoding: .utf8),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "spoken-margins-shared-link-test",
            encodedContentRuleList: AppOwnedReadablePageExtractor.readablePageContentRules
        )
        configuration.userContentController.add(try XCTUnwrap(rules))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer { webView.stopLoading(); webView.navigationDelegate = nil; self.webView = nil }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(String(decoding: data, as: UTF8.self), baseURL: url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return globalThis.SpokenMarginsBrowserTextCapture.captureReadablePage(document);",
                    arguments: [:], in: nil, contentWorld: .defaultClient
                )
                var payload = try XCTUnwrap(result as? [String: Any])
                // loadHTMLString can give the DOM about:blank. A real HTTPS load uses the response URL.
                var source = try XCTUnwrap(payload["source"] as? [String: Any])
                source["url"] = try XCTUnwrap(documentURL).absoluteString
                payload["source"] = source
                lastExtractor = (payload["metadata"] as? [String: Any])?["extractor"] as? String
                finish(.success(try AppOwnedReadablePageExtractor.handoff(from: payload)))
            } catch { finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<BrowserTextHandoff, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class RecordedSubstackURLProtocol: URLProtocol, @unchecked Sendable {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordedSubstackURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            guard url.host == "garymarcus.substack.com" else { throw URLError(.notConnectedToInternet) }
            let body: Data
            let status: Int
            if url.path == "/p/deleted" {
                body = Data("Page not found".utf8)
                status = 404
            } else {
                let feed = url.path == "/feed"
                guard feed || url.path == "/p/breaking-ai-agent-incident-toll-has" else {
                    throw URLError(.notConnectedToInternet)
                }
                let fixture = try XCTUnwrap(Bundle(for: SourceLinkShareFallbackTests.self).url(
                    forResource: feed ? "substack-shared-text-feed" : "substack-shared-text-post",
                    withExtension: feed ? "xml" : "html"
                ))
                body = try Data(contentsOf: fixture)
                status = 200
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": url.path == "/feed" ? "application/rss+xml" : "text/html"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}

    /// The app's injected podcast resolver is synchronous; URLProtocol callbacks run off the main actor.
    static func fetch(_ url: URL) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = FetchResult()
        session.dataTask(with: url) { data, response, error in
            if let error { result.value = .failure(error) }
            else if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let data {
                result.value = .success(data)
            } else { result.value = .failure(URLError(.badServerResponse)) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.value.get()
    }
}

/// The semaphore publishes the callback's single write before the resolver reads it.
private final class FetchResult: @unchecked Sendable {
    var value: Result<Data, Error> = .failure(URLError(.unknown))
}
