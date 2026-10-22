import XCTest
import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// #145: one Paste & go adds a podcast link, an article link or copied text, and an article the app
/// can't read offers Safari without creating anything. Links resolve through the real resolver against
/// recorded responses (PasteAndGoURLProtocol); WebKit can't be stubbed, so the article extractor is.
@MainActor
final class PasteAndGoTests: XCTestCase {
    /// Gate1AppModel's `guidedOnboardingTombstoneKey`, which is private. While it is unset, every model fetches the
    /// guided tour in the background and adds its row to the library mid-test. A test that started the tour earlier
    /// in the same run clears it, so "creates nothing" saw `[guided-onboarding, item-pill]` (#878).
    private static let guidedTourTombstoneKey = "guidedOnboardingTombstone"
    private var priorGuidedTourTombstone: Any?

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(PasteAndGoURLProtocol.self)
        priorGuidedTourTombstone = UserDefaults.standard.object(forKey: Self.guidedTourTombstoneKey)
        UserDefaults.standard.set(true, forKey: Self.guidedTourTombstoneKey)
    }

    override func tearDown() {
        if let priorGuidedTourTombstone {
            UserDefaults.standard.set(priorGuidedTourTombstone, forKey: Self.guidedTourTombstoneKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.guidedTourTombstoneKey)
        }
        URLProtocol.unregisterClass(PasteAndGoURLProtocol.self)
        super.tearDown()
    }

    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        return model
    }

    func testCopiedTextBecomesATextItemWithoutChangingNowPlayingOrTheTextDraft() throws {
        let model = makeModel()
        let snapshotBefore = model.snapshot
        let selectedBefore = model.selectedItem.id
        model.importText = "A draft the listener was typing"
        let pasted = """
        Field notes on listening slowly to long essays in the evening

        The second paragraph says more.
        """

        XCTAssertEqual(model.pasteAndGo(pasted), .addedText)

        let row = try XCTUnwrap(model.libraryItems.first { $0.title == "Field notes on listening slowly to long essays" })
        XCTAssertEqual(row.mediaType, "text")
        XCTAssertEqual(model.snapshot, snapshotBefore, "Now Playing is unchanged")
        XCTAssertEqual(model.selectedItem.id, selectedBefore)
        XCTAssertEqual(model.importText, "A draft the listener was typing")
        XCTAssertNil(model.lastError)
    }

    func testAnEmptyClipboardCreatesNothingAndSaysWhy() {
        let model = makeModel()
        let before = model.libraryItems.map(\.id)

        XCTAssertEqual(model.pasteAndGo("  \n "), .notAdded(ClipboardIntakeUnusableReason.empty.message))
        XCTAssertEqual(model.pasteAndGo("file:///tmp/notes.txt"), .notAdded(ClipboardIntakeUnusableReason.unsupportedLink(scheme: "file").message))

        XCTAssertEqual(model.libraryItems.map(\.id), before)
    }

    func testARecordedPodcastFeedLinkBecomesAPodcastItem() async throws {
        let model = makeModel()

        XCTAssertEqual(model.pasteAndGo("  \(PasteAndGoURLProtocol.feedURL)\n"), .resolvingLink)
        try await waitFor("podcast link import") { model.sourceLinkImportState != "resolving" }

        XCTAssertEqual(model.sourceLinkImportState, "success", model.sourceLinkImportMessage ?? "")
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == "Episode one of the recorded show" })
        XCTAssertNotEqual(row.mediaType, "text")
        XCTAssertNil(model.sourceLinkSafariOffer)
    }

    func testARecordedArticlePageBecomesATextItem() async throws {
        let model = makeModel()
        let articleURL = try XCTUnwrap(URL(string: PasteAndGoURLProtocol.articleURL))
        let extractor = PasteAndGoPageExtractor(.success(BrowserTextHandoff(
            itemId: "item-browser-paste-and-go-article",
            captureMode: .readablePage,
            source: BrowserTextSource(url: articleURL.absoluteString, title: "A recorded article"),
            text: "# A recorded article\n\nThe article's first paragraph.",
            contentFormat: .markdown
        )))
        model.readablePageExtractor = extractor

        XCTAssertEqual(model.pasteAndGo(PasteAndGoURLProtocol.articleURL), .resolvingLink)
        try await waitFor("article link import") { model.sourceLinkImportState != "resolving" }

        XCTAssertEqual(extractor.requested, [articleURL], "an article page goes to the article fallback")
        XCTAssertEqual(model.sourceLinkImportState, "success", model.sourceLinkImportMessage ?? "")
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == "A recorded article" })
        XCTAssertEqual(row.mediaType, "text")
    }

    /// #1379: the Library's "Add and play" offer asks for the session; the Add sheet's Paste & go never does.
    func testALinkAddedWithStartSessionPlaysItAtOnce() async throws {
        let model = makeModel()
        model.declineCurrentTerms()
        let articleURL = try XCTUnwrap(URL(string: PasteAndGoURLProtocol.articleURL))
        model.readablePageExtractor = PasteAndGoPageExtractor(.success(BrowserTextHandoff(
            itemId: "item-browser-paste-and-go-add-and-play",
            captureMode: .readablePage,
            source: BrowserTextSource(url: articleURL.absoluteString, title: "A recorded article"),
            text: "# A recorded article\n\nThe article's first paragraph.",
            contentFormat: .markdown
        )))
        model.openHome()

        XCTAssertEqual(model.pasteAndGo(PasteAndGoURLProtocol.articleURL, startSession: true), .resolvingLink)
        try await waitFor("article link import") { model.sourceLinkImportState != "resolving" }

        XCTAssertEqual(model.sourceLinkImportState, "success", model.sourceLinkImportMessage ?? "")
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == "A recorded article" })
        XCTAssertEqual(model.libraryItems.filter { $0.title == "A recorded article" }.count, 1, "exactly one item is added")
        XCTAssertEqual(model.snapshot.itemId, row.id, "the added item is the one playing")
    }

    /// #828: an article added with nothing in Now Playing gets the same "Added <title> to Library." and
    /// Play now as other adds, stays on the screen it was added from, and doesn't play by itself.
    func testARecordedArticleOffersPlayNowAndStaysOnTheScreenItWasAddedFrom() async throws {
        let model = makeModel()
        model.declineCurrentTerms()
        let articleURL = try XCTUnwrap(URL(string: PasteAndGoURLProtocol.articleURL))
        model.readablePageExtractor = PasteAndGoPageExtractor(.success(BrowserTextHandoff(
            itemId: "item-browser-paste-and-go-play-now",
            captureMode: .readablePage,
            source: BrowserTextSource(url: articleURL.absoluteString, title: "A recorded article"),
            text: "# A recorded article\n\nThe article's first paragraph.",
            contentFormat: .markdown
        )))
        model.openHome()
        model.dismissFeedback()

        XCTAssertEqual(model.pasteAndGo(PasteAndGoURLProtocol.articleURL), .resolvingLink)
        try await waitFor("article link import") { model.sourceLinkImportState != "resolving" }

        XCTAssertEqual(model.screen, .home)
        XCTAssertNil(model.snapshot.sessionId, "Nothing plays by itself")
        let event = try XCTUnwrap(model.feedbackEvent)
        XCTAssertEqual(event.message, "Added A recorded article to Library.")
        let action = try XCTUnwrap(event.action, "Play now must be offered when Now Playing is empty")
        XCTAssertEqual(action.title, "Play now")

        action.perform()
        let row = try XCTUnwrap(model.libraryItems.first { $0.title == "A recorded article" })
        XCTAssertEqual(model.snapshot.itemId, row.id)
        XCTAssertEqual(model.screen, .playback)
    }

    func testAnArticlePageThatAnswers403OffersSafariAndCreatesNothing() async throws {
        let model = makeModel()
        let before = model.libraryItems.map(\.id)
        model.readablePageExtractor = PasteAndGoPageExtractor(.failure(ReadablePageExtractionError.httpStatus(403)))

        XCTAssertEqual(model.pasteAndGo(PasteAndGoURLProtocol.articleURL), .resolvingLink)
        try await waitFor("article fallback failure") { model.sourceLinkImportState != "resolving" }

        XCTAssertEqual(model.sourceLinkImportState, "failure")
        let offer = try XCTUnwrap(model.sourceLinkSafariOffer)
        XCTAssertEqual(offer.url.absoluteString, PasteAndGoURLProtocol.articleURL)
        XCTAssertEqual(model.sourceLinkImportMessage, offer.message)
        XCTAssertTrue(offer.message.contains("HTTP 403"), offer.message)
        XCTAssertEqual(model.libraryItems.map(\.id), before)
    }

    func testAPageThatRefusesTheResolverOffersSafariAndCreatesNothing() async throws {
        let model = makeModel()
        let before = model.libraryItems.map(\.id)

        XCTAssertEqual(model.pasteAndGo(PasteAndGoURLProtocol.refusedURL), .resolvingLink)
        try await waitFor("refused page") { model.sourceLinkImportState != "resolving" }

        XCTAssertEqual(model.sourceLinkImportState, "failure")
        XCTAssertEqual(model.sourceLinkSafariOffer?.url.absoluteString, PasteAndGoURLProtocol.refusedURL)
        XCTAssertEqual(model.libraryItems.map(\.id), before)

        model.resetSourceLinkImportState()
        XCTAssertNil(model.sourceLinkSafariOffer)
    }

    func testOfflineFailuresDoNotOfferSafari() {
        XCTAssertNil(Gate1AppModel.safariOfferReason(for: URLError(.notConnectedToInternet)))
        XCTAssertNil(Gate1AppModel.safariOfferReason(for: URLError(.timedOut)))
        XCTAssertNotNil(Gate1AppModel.safariOfferReason(for: URLError(.badServerResponse)))
        XCTAssertNotNil(Gate1AppModel.safariOfferReason(for: ReadablePageExtractionError.invalidResult))
    }

    func testTheExtractorTreatsAnErrorStatusAsAFailureInsteadOfAnArticle() throws {
        let url = try XCTUnwrap(URL(string: "https://paste-and-go.example/a"))
        let forbidden = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil))
        let fine = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        XCTAssertEqual(AppOwnedReadablePageExtractor.failingHTTPStatus(forbidden), 403)
        XCTAssertNil(AppOwnedReadablePageExtractor.failingHTTPStatus(fine))
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 25_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let interval: UInt64 = 20_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail("Timed out waiting for \(description).")
    }
}

/// Stands in for the WebKit extractor, which tests can't drive.
private final class PasteAndGoPageExtractor: ReadablePageExtracting {
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
        let handoff = try outcome.get()
        lastExtractor = "recorded"
        return handoff
    }
}

/// Recorded responses for the one host these tests use: a podcast feed, an article page and a 403.
private final class PasteAndGoURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "paste-and-go.example"
    static let feedURL = "https://paste-and-go.example/show/feed.rss"
    static let articleURL = "https://paste-and-go.example/p/an-article"
    static let refusedURL = "https://paste-and-go.example/p/members-only"

    private static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>The recorded show</title>
        <link>https://paste-and-go.example/show</link>
        <description>A show recorded for tests.</description>
        <item>
          <title>Episode one of the recorded show</title>
          <guid>paste-and-go-episode-1</guid>
          <pubDate>Wed, 30 Sep 2026 12:00:00 GMT</pubDate>
          <itunes:duration>00:20:00</itunes:duration>
          <enclosure url="https://paste-and-go.example/show/episode-1.mp3" length="1000" type="audio/mpeg"/>
        </item>
      </channel>
    </rss>
    """

    private static let article = """
    <!doctype html>
    <html><head><title>A recorded article</title></head>
    <body><article><h1>A recorded article</h1><p>The article's first paragraph.</p></article></body></html>
    """

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, type, body): (Int, String, String) = switch url.absoluteString {
        case Self.feedURL: (200, "application/rss+xml", Self.feed)
        case Self.articleURL: (200, "text/html; charset=utf-8", Self.article)
        case Self.refusedURL: (403, "text/html; charset=utf-8", "<html><body>Members only</body></html>")
        default: (404, "text/plain", "Not found")
        }
        let data = Data(body.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
