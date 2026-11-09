import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #3817: the guards in `FollowedSourceCoordinator.discover` that keep the "Follow this source" card honest, each
/// against a stubbed network: no feed, a broken feed, a feed without the article, an oversized page or feed, a
/// plain-http page, a long redirect chain, and pages with several feeds. Each test uses its own host.
final class FollowDiscoveryGuardTests: XCTestCase {
    private static let maximumPageBytes = 1 * 1_024 * 1_024
    private static let maximumFeedBytes = 16 * 1_024 * 1_024

    /// The session the app makes for itself, redirect rule included, with only the transport stubbed.
    private func coordinator() -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryStubProtocol.self]
        return FollowedSourceCoordinator(
            repository: InMemorySessionRepository(),
            session: FollowedSourceCoordinator.boundedSession(configuration: configuration),
            signals: nil
        )
    }

    /// The diagnostic code of the error `discover` throws, or nil when it returns candidates.
    private func failure(_ coordinator: FollowedSourceCoordinator, _ link: String, requiringItemMembership: Bool = false) async -> String? {
        do {
            _ = try await coordinator.discover(urlString: link, requiringItemMembership: requiringItemMembership)
            return nil
        } catch {
            return FollowedSourceCoordinator.diagnosticCode(for: error)
        }
    }

    // MARK: Pages with no usable feed

    func testAPageWithNoFeedLinkGivesNoCandidates() async throws {
        DiscoveryStubProtocol.serve("https://nofeed.example/article", .html(page(links: [])))
        let coordinator = coordinator()

        let code = await failure(coordinator, "https://nofeed.example/article")

        XCTAssertEqual(code, "no_feed_candidates")
        let asked = DiscoveryStubProtocol.requests(host: "nofeed.example")
        for path in ["/feed", "/feed.xml", "/rss", "/atom.xml"] {
            XCTAssertTrue(asked.contains("https://nofeed.example\(path)"), "the same-origin guess \(path) is tried")
        }
    }

    func testAFeedLinkThatReturnsHTMLIsSkipped() async throws {
        DiscoveryStubProtocol.serve("https://broken.example/article", .html(page(links: ["/broken.xml"])))
        DiscoveryStubProtocol.serve("https://broken.example/broken.xml", .html("<html><body>Not a feed</body></html>"))
        let coordinator = coordinator()

        let code = await failure(coordinator, "https://broken.example/article")

        XCTAssertEqual(code, "no_feed_candidates", "a feed that fails to parse is skipped, not reported as the failure")
        XCTAssertTrue(DiscoveryStubProtocol.requests(host: "broken.example").contains("https://broken.example/broken.xml"))
    }

    func testABrokenFeedDoesNotHideAGoodOneAfterIt() async throws {
        DiscoveryStubProtocol.serve("https://mixed.example/article", .html(page(links: ["/broken.xml", "/good.xml"])))
        DiscoveryStubProtocol.serve("https://mixed.example/broken.xml", .html("<html><body>Not a feed</body></html>"))
        DiscoveryStubProtocol.serve("https://mixed.example/good.xml", .feed(rss(title: "Mixed", links: ["https://mixed.example/article"])))
        let coordinator = coordinator()

        let candidates = try await coordinator.discover(urlString: "https://mixed.example/article")

        XCTAssertEqual(candidates.map(\.source.canonicalURL), ["https://mixed.example/good.xml"])
    }

    // MARK: Membership

    func testAFeedWithoutTheArticleIsDroppedOnlyWhenMembershipIsRequired() async throws {
        DiscoveryStubProtocol.serve("https://unrelated.example/article", .html(page(links: ["/feed.xml"])))
        DiscoveryStubProtocol.serve("https://unrelated.example/feed.xml", .feed(rss(title: "Unrelated", links: [
            "https://unrelated.example/other", "https://unrelated.example/another",
        ])))

        let required = await failure(coordinator(), "https://unrelated.example/article", requiringItemMembership: true)
        XCTAssertEqual(required, "no_feed_candidates", "a feed that doesn't list the article is no evidence of its source")

        let candidates = try await coordinator().discover(urlString: "https://unrelated.example/article", requiringItemMembership: false)
        XCTAssertEqual(candidates.map(\.source.canonicalURL), ["https://unrelated.example/feed.xml"])
    }

    func testAFeedThatListsTheArticleIsKeptWhenMembershipIsRequired() async throws {
        DiscoveryStubProtocol.serve("https://member.example/article", .html(page(links: ["/feed.xml"])))
        // The entry differs from the link only by host case and a fragment, which the match ignores.
        DiscoveryStubProtocol.serve("https://member.example/feed.xml", .feed(rss(title: "Member", links: [
            "https://unrelated.example/other", "https://MEMBER.example/article#comments",
        ])))

        let candidates = try await coordinator().discover(urlString: "https://member.example/article", requiringItemMembership: true)

        XCTAssertEqual(candidates.map(\.source.canonicalURL), ["https://member.example/feed.xml"])
    }

    // MARK: Size limits

    func testAPageAtTheOneMegabyteLimitIsReadAndOneByteMoreIsRefused() async throws {
        DiscoveryStubProtocol.serve("https://pagesize.example/at-limit", .html(page(links: ["/feed.xml"], totalBytes: Self.maximumPageBytes)))
        DiscoveryStubProtocol.serve("https://pagesize.example/over-limit", .html(page(links: ["/feed.xml"], totalBytes: Self.maximumPageBytes + 1)))
        DiscoveryStubProtocol.serve("https://pagesize.example/feed.xml", .feed(rss(title: "Sized", links: ["https://pagesize.example/x"])))

        let candidates = try await coordinator().discover(urlString: "https://pagesize.example/at-limit")
        XCTAssertEqual(candidates.map(\.source.canonicalURL), ["https://pagesize.example/feed.xml"])

        let code = await failure(coordinator(), "https://pagesize.example/over-limit")
        XCTAssertEqual(code, "html_response_too_large", "a page over 1 MB is never searched for feed links")
    }

    func testAFeedAtTheSixteenMegabyteLimitIsReadAndOneByteMoreIsRefused() async throws {
        let atLimit = rss(title: "Big", links: ["https://feedsize.example/x"], totalBytes: Self.maximumFeedBytes)
        let overLimit = rss(title: "Big", links: ["https://feedsize.example/x"], totalBytes: Self.maximumFeedBytes + 1)
        XCTAssertEqual(atLimit.count, Self.maximumFeedBytes)
        XCTAssertEqual(overLimit.count, Self.maximumFeedBytes + 1)
        DiscoveryStubProtocol.serve("https://feedsize.example/at-limit.xml", .feed(atLimit))
        DiscoveryStubProtocol.serve("https://feedsize.example/over-limit.xml", .feed(overLimit))

        let candidates = try await coordinator().discover(urlString: "https://feedsize.example/at-limit.xml")
        XCTAssertEqual(candidates.map(\.relation), ["direct"])

        // The coordinator refuses the body before the parser sees it; its own code names the 16 MB limit.
        let coordinator = coordinator()
        let error = try await XCTUnwrapAsyncError { try await coordinator.discover(urlString: "https://feedsize.example/over-limit.xml") }
        let line = await coordinator.failureDiagnostic(for: error)
        XCTAssertTrue(line.contains("direct: not a feed (response_too_large)"), line)
    }

    func testAnOversizedFeedLinkedFromAPageIsSkipped() async throws {
        DiscoveryStubProtocol.serve("https://bigfeed.example/article", .html(page(links: ["/feed.xml"])))
        DiscoveryStubProtocol.serve("https://bigfeed.example/feed.xml", .feed(rss(title: "Big", links: ["https://bigfeed.example/article"], totalBytes: Self.maximumFeedBytes + 1)))

        let code = await failure(coordinator(), "https://bigfeed.example/article")

        XCTAssertEqual(code, "no_feed_candidates")
    }

    // MARK: Transport

    func testAPlainHTTPPageIsNeverRequested() async throws {
        DiscoveryStubProtocol.serve("http://plain.example/article", .html(page(links: ["https://plain.example/feed.xml"])))
        DiscoveryStubProtocol.serve("https://plain.example/feed.xml", .feed(rss(title: "Plain", links: ["http://plain.example/article"])))

        let code = await failure(coordinator(), "http://plain.example/article")

        XCTAssertEqual(code, "insecure_url")
        XCTAssertFalse(DiscoveryStubProtocol.requests(host: "plain.example").contains("http://plain.example/article"))
    }

    #if !canImport(FoundationNetworking)
    // Redirect handling through a custom URLProtocol differs on Linux; the rule runs on the Mac.
    func testFiveRedirectsAreFollowedAndASixthIsRefused() async throws {
        // /hop/N redirects to /hop/N-1; /hop/0 is the feed.
        for hop in 1...6 {
            DiscoveryStubProtocol.serve("https://redirects.example/hop/\(hop)", .redirect(to: "https://redirects.example/hop/\(hop - 1)"))
        }
        DiscoveryStubProtocol.serve("https://redirects.example/hop/0", .feed(rss(title: "Hops", links: ["https://redirects.example/x"])))

        let candidates = try await coordinator().discover(urlString: "https://redirects.example/hop/5")
        XCTAssertEqual(candidates.map(\.relation), ["direct"], "five redirects reach the feed")
        XCTAssertEqual(candidates.first?.source.canonicalURL, "https://redirects.example/hop/0")

        DiscoveryStubProtocol.forget(host: "redirects.example")
        let code = await failure(coordinator(), "https://redirects.example/hop/6")
        XCTAssertNotNil(code, "a sixth redirect is not followed")
        XCTAssertFalse(DiscoveryStubProtocol.requests(host: "redirects.example").contains("https://redirects.example/hop/0"))
    }

    func testARedirectToPlainHTTPIsRefused() async throws {
        DiscoveryStubProtocol.serve("https://downgrade.example/feed.xml", .redirect(to: "http://downgrade.example/feed.xml"))
        DiscoveryStubProtocol.serve("http://downgrade.example/feed.xml", .feed(rss(title: "Downgrade", links: ["https://downgrade.example/x"])))

        let code = await failure(coordinator(), "https://downgrade.example/feed.xml")

        XCTAssertNotNil(code)
        XCTAssertFalse(DiscoveryStubProtocol.requests(host: "downgrade.example").contains("http://downgrade.example/feed.xml"))
    }
    #endif

    // MARK: Several feeds

    func testTwoFeedsWithDifferentEntriesAreBothOffered() async throws {
        DiscoveryStubProtocol.serve("https://twofeeds.example/article", .html(page(links: ["/news.xml", "/essays.xml"])))
        DiscoveryStubProtocol.serve("https://twofeeds.example/news.xml", .feed(rss(title: "Two Feeds", links: ["https://twofeeds.example/article", "https://twofeeds.example/news-1"])))
        DiscoveryStubProtocol.serve("https://twofeeds.example/essays.xml", .feed(rss(title: "Two Feeds", links: ["https://twofeeds.example/article", "https://twofeeds.example/essay-1"])))

        let candidates = try await coordinator().discover(urlString: "https://twofeeds.example/article", requiringItemMembership: true)

        XCTAssertEqual(candidates.map(\.source.canonicalURL), ["https://twofeeds.example/news.xml", "https://twofeeds.example/essays.xml"])
        XCTAssertEqual(Set(candidates.map(\.source.id)).count, 2)
    }

    func testTwoFeedURLsWithTheSameEntriesAreOfferedOnce() async throws {
        let entries = ["https://samefeeds.example/article", "https://samefeeds.example/older"]
        DiscoveryStubProtocol.serve("https://samefeeds.example/article", .html(page(links: ["/rss.xml", "/atom.xml?format=alt"])))
        DiscoveryStubProtocol.serve("https://samefeeds.example/rss.xml", .feed(rss(title: "Same as RSS", links: entries)))
        // Another title and the entries in another order: membership decides, not the title.
        DiscoveryStubProtocol.serve("https://samefeeds.example/atom.xml?format=alt", .feed(rss(title: "Same as Atom", links: entries.reversed())))

        let candidates = try await coordinator().discover(urlString: "https://samefeeds.example/article")

        XCTAssertEqual(candidates.map(\.source.canonicalURL), ["https://samefeeds.example/rss.xml"])
    }

    func testAtMostEightFeedsAreFetched() async throws {
        let links = (1...10).map { "/feed-\($0).xml" }
        DiscoveryStubProtocol.serve("https://manyfeeds.example/article", .html(page(links: links)))
        for number in 1...10 {
            DiscoveryStubProtocol.serve("https://manyfeeds.example/feed-\(number).xml", .feed(rss(title: "Feed \(number)", links: ["https://manyfeeds.example/only-in-\(number)"])))
        }

        let candidates = try await coordinator().discover(urlString: "https://manyfeeds.example/article")

        XCTAssertEqual(candidates.map(\.source.canonicalURL), (1...8).map { "https://manyfeeds.example/feed-\($0).xml" })
        let asked = DiscoveryStubProtocol.requests(host: "manyfeeds.example")
        for unasked in ["/feed-9.xml", "/feed-10.xml", "/feed.xml", "/rss", "/atom.xml"] {
            XCTAssertFalse(asked.contains("https://manyfeeds.example\(unasked)"), "\(unasked) is past the eighth candidate")
        }
    }

    // MARK: The suggestion card

    func testTheCardShowsAddressesOnlyForCandidatesThatShareATitle() {
        func candidate(_ id: String, title: String?) -> SourceCandidateEvidence {
            SourceCandidateEvidence(id: id, source: SourceIdentity(id: id, kind: .articleFeed, canonicalURL: "https://cards.example/\(id).xml",
                host: "cards.example", title: title), evidenceURL: "https://cards.example/article", relation: "html_alternate", confidence: 0.95)
        }
        let news = candidate("news", title: "Cards")
        let essays = candidate("essays", title: "Cards")
        let other = candidate("other", title: "Other")
        let all = [news, essays, other]

        XCTAssertTrue(news.showsFeedURL(among: all))
        XCTAssertTrue(essays.showsFeedURL(among: all))
        XCTAssertFalse(other.showsFeedURL(among: all))
        XCTAssertFalse(news.showsFeedURL(among: [news]), "a lone candidate needs no address")
        XCTAssertTrue(candidate("a", title: nil).showsFeedURL(among: [candidate("a", title: nil), candidate("b", title: nil)]),
            "two untitled feeds both show the host as their name, so both show their address")
    }

    // MARK: Fixtures

    /// An article page linking `links` as RSS alternates, padded with a comment to exactly `totalBytes` when given.
    private func page(links: [String], totalBytes: Int? = nil) -> String {
        let head = links.map { #"<link rel="alternate" type="application/rss+xml" href="\#($0)">"# }.joined()
        let open = "<html><head><title>Article</title>\(head)</head><body><p>Article text.</p>"
        let close = "</body></html>"
        return open + padding(toFill: totalBytes.map { $0 - open.utf8.count - close.utf8.count }) + close
    }

    /// An RSS feed whose items link to `links`, with no self link, padded to exactly `totalBytes` when given.
    private func rss(title: String, links: [String], totalBytes: Int? = nil) -> Data {
        let items = links.enumerated().map { index, link in
            "<item><title>Entry \(index)</title><link>\(link.replacingOccurrences(of: "&", with: "&amp;"))</link><guid>\(link.replacingOccurrences(of: "&", with: "&amp;"))</guid></item>"
        }.joined()
        let open = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>\#(title)</title><link>https://example.com</link>\#(items)"#
        let close = "</channel></rss>"
        return Data((open + padding(toFill: totalBytes.map { $0 - open.utf8.count - close.utf8.count }) + close).utf8)
    }

    /// XML/HTML comments filling exactly `bytes` bytes, or nothing. Each is at most 1 MB, because the XML parser
    /// refuses a single text node over 10 MB.
    private func padding(toFill bytes: Int?) -> String {
        guard var remaining = bytes else { return "" }
        precondition(remaining >= 7, "too small to pad")
        func comment(_ size: Int) -> String { "<!--" + String(repeating: "x", count: size - 7) + "-->" }
        var comments: [String] = []
        while remaining > 1_000_007 {
            comments.append(comment(1_000_000))
            remaining -= 1_000_000
        }
        comments.append(comment(remaining))
        return comments.joined()
    }

    private func XCTUnwrapAsyncError(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws -> Error {
        do {
            try await body()
        } catch {
            return error
        }
        XCTFail("expected an error", file: file, line: line)
        throw FollowedSourceError.invalidResponse
    }
}

/// Serves what each test registers, by full URL; anything else is a 404. Keeps every URL it was asked for.
private final class DiscoveryStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case html(String)
        case feed(Data)
        case redirect(to: String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var asked: [String] = []

    static func serve(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    static func requests(host: String) -> [String] {
        lock.withLock { asked.filter { URL(string: $0)?.host?.lowercased() == host } }
    }

    /// Clears what `host` was asked, keeping its replies.
    static func forget(host: String) {
        lock.withLock { asked.removeAll { URL(string: $0)?.host?.lowercased() == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.asked.append(url.absoluteString)
            return Self.replies[url.absoluteString]
        }
        switch reply {
        case let .redirect(to: location)?:
            guard let next = URL(string: location),
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
            // When the session refuses the redirect, the 302 is the answer. When it follows it, the session has
            // already moved to the next request and ignores these (seen on macOS with five and with fifty hops).
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .html(text)?:
            finish(url: url, status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8))
        case let .feed(data)?:
            finish(url: url, status: 200, contentType: "application/rss+xml", body: data)
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
