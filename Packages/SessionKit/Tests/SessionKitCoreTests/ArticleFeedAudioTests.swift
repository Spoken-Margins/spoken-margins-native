import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #4640: the article feed route. An article whose own public feed lists it with an audio enclosure offers that audio;
/// audio that a page plays only in its own player is never taken. Each test uses its own host.
final class ArticleFeedAudioTests: XCTestCase {
    private func coordinator() -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArticleFeedStubProtocol.self]
        return FollowedSourceCoordinator(
            repository: InMemorySessionRepository(),
            session: FollowedSourceCoordinator.boundedSession(configuration: configuration),
            signals: nil
        )
    }

    // MARK: Fixtures

    private func page(feedLinks: [String] = ["/feed.xml"], body: String = "<p>Article text.</p>", head: String = "") -> String {
        let links = feedLinks.map { #"<link rel="alternate" type="application/rss+xml" href="\#($0)">"# }.joined()
        return "<html><head><title>Article</title>\(links)\(head)</head><body>\(body)</body></html>"
    }

    private struct Entry {
        var link: String
        var enclosure: String? = nil
        var type: String? = "audio/mpeg"
        var length: Int? = nil
        var duration: String? = nil
    }

    private func rss(_ entries: [Entry]) -> Data {
        let items = entries.map { entry -> String in
            let enclosure = entry.enclosure.map { url in
                #"<enclosure url="\#(url.replacingOccurrences(of: "&", with: "&amp;"))""#
                    + (entry.length.map { #" length="\#($0)""# } ?? "")
                    + (entry.type.map { #" type="\#($0)""# } ?? "") + "/>"
            } ?? ""
            let duration = entry.duration.map { "<itunes:duration>\($0)</itunes:duration>" } ?? ""
            let link = entry.link.replacingOccurrences(of: "&", with: "&amp;")
            return "<item><title>Post</title><link>\(link)</link><guid>\(link)</guid>\(enclosure)\(duration)</item>"
        }.joined()
        return Data(#"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Site</title><link>https://example.com</link>\#(items)</channel></rss>"#.utf8)
    }

    /// Serves a page linking /feed.xml and the feed holding `entries`.
    private func serve(host: String, path: String = "/posts/kettleness", entries: [Entry]) -> URL {
        ArticleFeedStubProtocol.serve("https://\(host)\(path)", .html(page()))
        ArticleFeedStubProtocol.serve("https://\(host)/feed.xml", .feed(rss(entries)))
        return URL(string: "https://\(host)\(path)")!
    }

    private func outcome(_ url: URL, words: Int? = 900) async -> ArticleFeedAudioOutcome {
        await coordinator().articleFeedAudio(pageURL: url, bodyWordCount: words)
    }

    // MARK: Found

    func testAFeedItemWithAnMp3EnclosureIsFound() async {
        let url = serve(host: "found.example", entries: [
            Entry(link: "https://found.example/posts/other", enclosure: "https://cdn.found.example/other.mp3", duration: "6:00"),
            Entry(link: "https://found.example/posts/kettleness", enclosure: "https://cdn.found.example/kettleness.mp3", length: 5_000_000, duration: "6:00"),
        ])

        let result = await outcome(url)

        XCTAssertEqual(result, .found(audioURL: "https://cdn.found.example/kettleness.mp3", durationMs: 360_000, lengthBytes: 5_000_000))
    }

    /// A page whose text is the episode's full transcript lines up with the episode, so the route finds it and the
    /// text map decides later.
    func testATranscriptPodcastItemLinkingThePageIsFound() async {
        let url = serve(host: "transcript.example", path: "/episode", entries: [
            Entry(link: "https://transcript.example/episode", enclosure: "https://transcript.example/episode.mp3", duration: "00:07:30"),
        ])

        guard case .found = await outcome(url) else { return XCTFail("the transcript page's own episode is found") }
    }

    /// The shipped fixture's enclosure has a length of 0 and no duration: no size, so nothing to judge it by.
    func testTheShippedTranscriptFixtureHasNoSize() async throws {
        let feed = try TestInputs.data(.contracts, "fixtures/feeds/substack-transcript-podcast.rss")
        ArticleFeedStubProtocol.serve("https://podcast.example/episode", .html(page()))
        ArticleFeedStubProtocol.serve("https://podcast.example/feed.xml", .feed(feed))

        let result = await outcome(URL(string: "https://podcast.example/episode")!)

        XCTAssertEqual(result, .none(reason: "no_size"))
    }

    // MARK: Pages that play audio only in their own player fall back

    func testOpenAIShapedPageGivesNothing() async {
        let languages = (0..<40).map { #"<link rel="alternate" hreflang="l\#($0)" href="https://openai-shaped.example/l\#($0)/index/risk/">"# }.joined()
        ArticleFeedStubProtocol.serve("https://openai-shaped.example/index/risk/", .html(page(feedLinks: [], head: languages)))
        ArticleFeedStubProtocol.serve("https://openai-shaped.example/feed.xml",
            .feed(rss([Entry(link: "https://openai-shaped.example/index/risk/", enclosure: nil)])))

        let result = await outcome(URL(string: "https://openai-shaped.example/index/risk/")!)

        XCTAssertEqual(result, .none(reason: "not_listed"))
    }

    func testPageMarkupAudioIsNeverTaken() async {
        let shapes: [(String, String, String)] = [
            ("native-audio.example", "", #"<audio controls src="https://native-audio.example/a.mp3"></audio>"#),
            ("og-audio.example", #"<meta property="og:audio" content="https://og-audio.example/a.mp3">"#, ""),
            ("jsonld.example", #"<script type="application/ld+json">{"@type":"AudioObject","contentUrl":"https://jsonld.example/a.mp3"}</script>"#, ""),
            ("beyondwords.example", "", #"<iframe src="https://audio.beyondwords.io/e/1"></iframe>"#),
        ]
        for (host, head, body) in shapes {
            ArticleFeedStubProtocol.serve("https://\(host)/post", .html(page(feedLinks: [], body: body, head: head)))

            let result = await outcome(URL(string: "https://\(host)/post")!)

            XCTAssertEqual(result, .none(reason: "not_listed"), host)
        }
    }

    // MARK: Refusals

    func testRefusedEnclosures() async {
        let cases: [(String, Entry, Int?, String)] = [
            ("other-posts.example", Entry(link: "https://other-posts.example/elsewhere", enclosure: "https://other-posts.example/a.mp3", duration: "6:00"), 900, "not_listed"),
            ("signed.example", Entry(link: "https://signed.example/posts/kettleness", enclosure: "https://cdn.signed.example/a.mp3?X-Amz-Signature=x", duration: "6:00"), 900, "signed_url"),
            ("hls.example", Entry(link: "https://hls.example/posts/kettleness", enclosure: "https://cdn.hls.example/a.m3u8", type: "application/vnd.apple.mpegurl", duration: "6:00"), 900, "hls_unsupported"),
            ("long.example", Entry(link: "https://long.example/posts/kettleness", enclosure: "https://cdn.long.example/a.mp3", duration: "45:00"), 900, "too_long"),
            ("short.example", Entry(link: "https://short.example/posts/kettleness", enclosure: "https://cdn.short.example/a.mp3", duration: "0:30"), 900, "too_short"),
            ("nosize.example", Entry(link: "https://nosize.example/posts/kettleness", enclosure: "https://cdn.nosize.example/a.mp3"), 900, "no_size"),
            ("zerosize.example", Entry(link: "https://zerosize.example/posts/kettleness", enclosure: "https://cdn.zerosize.example/a.mp3", length: 0), 900, "no_size"),
            ("insecure.example", Entry(link: "https://insecure.example/posts/kettleness", enclosure: "http://cdn.insecure.example/a.mp3", duration: "6:00"), 900, "insecure"),
            ("port.example", Entry(link: "https://port.example/posts/kettleness", enclosure: "https://cdn.port.example:8443/a.mp3", duration: "6:00"), 900, "insecure"),
            ("video.example", Entry(link: "https://video.example/posts/kettleness", enclosure: "https://cdn.video.example/a.mp4", type: "video/mp4", duration: "6:00"), 900, "not_audio"),
            ("shortbody.example", Entry(link: "https://shortbody.example/posts/kettleness", enclosure: "https://cdn.shortbody.example/a.mp3", duration: "1:00"), 150, "short_body"),
            ("samepage.example", Entry(link: "https://samepage.example/posts/kettleness", enclosure: "https://samepage.example/posts/kettleness", type: "audio/mpeg", duration: "6:00"), 900, "same_as_page"),
        ]
        for (host, entry, words, reason) in cases {
            let url = serve(host: host, entries: [entry])

            let result = await outcome(url, words: words)

            XCTAssertEqual(result, .none(reason: reason), host)
        }
    }

    func testAnEnclosureByExtensionWithNoTypeIsAudio() async {
        let url = serve(host: "notype.example", entries: [
            Entry(link: "https://notype.example/posts/kettleness", enclosure: "https://cdn.notype.example/a.m4a", type: nil, duration: "6:00"),
        ])
        guard case .found = await outcome(url) else { return XCTFail("an .m4a enclosure with no type is audio") }
    }

    func testAFeedAnswering401GivesNothing() async {
        ArticleFeedStubProtocol.serve("https://locked.example/post", .html(page()))
        ArticleFeedStubProtocol.serve("https://locked.example/feed.xml", .status(401))

        let result = await outcome(URL(string: "https://locked.example/post")!)

        guard case .none = result else { return XCTFail("a refused feed gives nothing, got \(result)") }
    }

    // MARK: Matching the page

    func testPageKeyNeighbours() {
        let page = ArticleFeedAudioRules.pageKey("https://www.Example.com/posts/kettleness/")
        let same = [
            "https://example.com/posts/kettleness",
            "http://example.com/posts/kettleness",
            "https://www.example.com/posts/kettleness",
            "https://EXAMPLE.COM/posts/kettleness/",
            "https://example.com/posts/kettleness#comments",
            "https://example.com/posts/kettleness?utm_source=rss&utm_medium=feed",
            "https://example.com/posts/kettleness?fbclid=x&ref=home",
        ]
        for address in same { XCTAssertEqual(ArticleFeedAudioRules.pageKey(address), page, address) }
        let different = [
            "https://example.com/posts/kettleness-2",
            "https://example.com/posts",
            "https://example.com.evil.example/posts/kettleness",
            "https://notexample.com/posts/kettleness",
            "https://example.com/posts/kettleness?id=2",
            "ftp://example.com/posts/kettleness",
        ]
        for address in different { XCTAssertNotEqual(ArticleFeedAudioRules.pageKey(address), page, address) }
        XCTAssertNil(ArticleFeedAudioRules.pageKey(""))
        XCTAssertNil(ArticleFeedAudioRules.pageKey(nil))
    }

    func testTheMatcherTakesEitherPageKeyAndPrefersAnItemWithAnEnclosure() {
        let keys = Set(["https://short.example/p/123", "https://short.example/posts/kettleness"].compactMap(ArticleFeedAudioRules.pageKey))
        var bare = ParsedFeedItem(id: "1", title: "Post", url: "https://short.example/posts/kettleness/", audioURL: nil)
        var withAudio = bare
        withAudio.id = "2"
        withAudio.enclosureURL = "https://cdn.short.example/a.mp3"
        bare.url = "https://www.short.example/posts/kettleness?utm_source=rss"
        let other = ParsedFeedItem(id: "3", title: "Other", url: "https://short.example/posts/other", audioURL: nil)

        XCTAssertEqual(ArticleFeedAudioRules.matchingItem(in: [other, bare, withAudio], pageKeys: keys)?.id, "2")
        XCTAssertEqual(ArticleFeedAudioRules.matchingItem(in: [other, bare], pageKeys: keys)?.id, "1")
        XCTAssertNil(ArticleFeedAudioRules.matchingItem(in: [other], pageKeys: keys))
    }

    #if !canImport(FoundationNetworking)
    // swift-corelibs-foundation's URLSession can't follow a redirect from a URLProtocol, so this runs on Apple platforms.
    func testAFeedListingTheRedirectedAddressMatches() async {
        ArticleFeedStubProtocol.serve("https://redirect.example/p/123", .redirect("https://redirect.example/posts/kettleness"))
        ArticleFeedStubProtocol.serve("https://redirect.example/posts/kettleness", .html(page()))
        ArticleFeedStubProtocol.serve("https://redirect.example/feed.xml", .feed(rss([
            Entry(link: "https://redirect.example/posts/kettleness?utm_source=rss", enclosure: "https://cdn.redirect.example/a.mp3", duration: "6:00"),
        ])))

        guard case .found = await outcome(URL(string: "https://redirect.example/p/123")!) else {
            return XCTFail("the feed lists the page under the address it redirects to")
        }
    }
    #endif

    // MARK: Requests

    func testTheFollowCheckAndTheRouteTogetherFetchThePageOnce() async throws {
        let url = serve(host: "together.example", entries: [
            Entry(link: "https://together.example/posts/kettleness", enclosure: "https://cdn.together.example/a.mp3", duration: "6:00"),
        ])
        let coordinator = coordinator()

        async let follow = try? coordinator.discover(urlString: url.absoluteString)
        async let route = coordinator.articleFeedAudio(pageURL: url, bodyWordCount: 900)
        let (_, found) = await (follow, route)

        guard case .found = found else { return XCTFail("found") }
        // The same page discovered alone, on its own host, is the baseline: the route adds no page request.
        let alone = serve(host: "alone.example", entries: [])
        _ = try? await self.coordinator().discover(urlString: alone.absoluteString)
        XCTAssertEqual(ArticleFeedStubProtocol.htmlRequests(host: "together.example"), ArticleFeedStubProtocol.htmlRequests(host: "alone.example"))
    }

    func testDiscoverThenTheRouteFetchesThePageOnce() async throws {
        let url = serve(host: "sequence.example", entries: [
            Entry(link: "https://sequence.example/posts/kettleness", enclosure: "https://cdn.sequence.example/a.mp3", duration: "6:00"),
        ])
        let coordinator = coordinator()

        _ = try await coordinator.discover(urlString: url.absoluteString, requiringItemMembership: true)
        let afterFollowCheck = ArticleFeedStubProtocol.requests(host: "sequence.example").count
        let found = await coordinator.articleFeedAudio(pageURL: url, bodyWordCount: 900)

        guard case .found = found else { return XCTFail("found") }
        XCTAssertEqual(ArticleFeedStubProtocol.requests(host: "sequence.example").count, afterFollowCheck, "the route sends nothing new")
    }

    func testAFoundAnswerAskedAgainSendsNothing() async {
        let url = serve(host: "again.example", entries: [
            Entry(link: "https://again.example/posts/kettleness", enclosure: "https://cdn.again.example/a.mp3", duration: "6:00"),
        ])
        let coordinator = coordinator()
        _ = await coordinator.articleFeedAudio(pageURL: url, bodyWordCount: 900)
        let before = ArticleFeedStubProtocol.requests(host: "again.example").count

        let second = await coordinator.articleFeedAudio(pageURL: url, bodyWordCount: 900)
        let shortBody = await coordinator.articleFeedAudio(pageURL: url, bodyWordCount: 100)

        guard case .found = second else { return XCTFail("found again") }
        XCTAssertEqual(shortBody, .none(reason: "short_body"), "the rules run again with each caller's word count")
        XCTAssertEqual(ArticleFeedStubProtocol.requests(host: "again.example").count, before)
    }

    func testOfflineFailsAndTheNextCallFetchesAgain() async {
        ArticleFeedStubProtocol.serve("https://offline.example/post", .offline)
        let coordinator = coordinator()

        let first = await coordinator.articleFeedAudio(pageURL: URL(string: "https://offline.example/post")!, bodyWordCount: 900)
        let asked = ArticleFeedStubProtocol.htmlRequests(host: "offline.example")
        let second = await coordinator.articleFeedAudio(pageURL: URL(string: "https://offline.example/post")!, bodyWordCount: 900)

        guard case .failed(let token) = first else { return XCTFail("offline is a failure to retry, got \(first)") }
        XCTAssertTrue(token.hasPrefix("url_error_"), token)
        guard case .failed = second else { return XCTFail("still offline") }
        XCTAssertGreaterThan(ArticleFeedStubProtocol.htmlRequests(host: "offline.example"), asked, "the second call fetched again")
    }

    func testAnAddressThatIsItselfAFeedIsNotAnArticlePage() async {
        ArticleFeedStubProtocol.serve("https://feedpage.example/feed.xml", .feed(rss([
            Entry(link: "https://feedpage.example/feed.xml", enclosure: "https://cdn.feedpage.example/a.mp3", duration: "6:00"),
        ])))

        let result = await outcome(URL(string: "https://feedpage.example/feed.xml")!)

        XCTAssertEqual(result, .none(reason: "not_an_article_page"))
    }
}

/// Serves what each test registers, by full URL; anything else is a 404. Keeps every URL and Accept header it was asked.
private final class ArticleFeedStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case html(String)
        case feed(Data)
        case status(Int)
        case redirect(String)
        case offline
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var asked: [(url: String, accept: String)] = []

    static func serve(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    static func requests(host: String) -> [String] {
        lock.withLock { asked.filter { URL(string: $0.url)?.host?.lowercased() == host }.map(\.url) }
    }

    /// Requests for pages (Accept starting `text/html`) to `host`.
    static func htmlRequests(host: String) -> Int {
        lock.withLock { asked.filter { URL(string: $0.url)?.host?.lowercased() == host && $0.accept.hasPrefix("text/html") }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        let reply = Self.lock.withLock { () -> Reply? in
            Self.asked.append((url.absoluteString, accept))
            return Self.replies[url.absoluteString]
        }
        switch reply {
        case let .html(text)?:
            finish(url: url, status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8))
        case let .feed(data)?:
            finish(url: url, status: 200, contentType: "application/rss+xml", body: data)
        case let .status(code)?:
            finish(url: url, status: code, contentType: "text/plain", body: Data())
        case let .redirect(target)?:
            guard let targetURL = URL(string: target),
                  let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: ["Location": target]) else { return }
            var next = request
            next.url = targetURL
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .offline?:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case nil:
            finish(url: url, status: 404, contentType: "text/plain", body: Data())
        }
    }

    private func finish(url: URL, status: Int, contentType: String, body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": contentType, "Content-Length": "\(body.count)"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
