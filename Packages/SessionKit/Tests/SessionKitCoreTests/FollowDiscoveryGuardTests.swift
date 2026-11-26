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

        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation's XML parser (libxml2) refuses any document over about 10 MB whatever it holds, so on
        // Linux the 16 MB feed reaches the parser and is rejected there. The size guard must still have let it through.
        let atLimitCoordinator = coordinator()
        do {
            _ = try await atLimitCoordinator.discover(urlString: "https://feedsize.example/at-limit.xml")
            XCTFail("the Linux XML parser is expected to refuse a 16 MB document")
        } catch {
            let atLimitLine = await atLimitCoordinator.failureDiagnostic(for: error)
            XCTAssertTrue(atLimitLine.contains("direct: not a feed (feed_malformed)"), "at the limit the parser, not the size guard, speaks: \(atLimitLine)")
            XCTAssertFalse(atLimitLine.contains("not a feed (response_too_large)"), atLimitLine)
        }
        #else
        let candidates = try await coordinator().discover(urlString: "https://feedsize.example/at-limit.xml")
        XCTAssertEqual(candidates.map(\.relation), ["direct"])
        #endif

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

    // MARK: Redirects (#3817, #4681)
    //
    // These call the app's redirect delegate itself, hop by hop, instead of serving redirects from a stub
    // `URLProtocol`. What a session does after a protocol reports a redirect is not specified, and the stub's
    // five-hop test failed on the hosted Xcode 27 run with no change to the delegate (#4681); a stub that
    // can't follow also lets a "redirect is refused" test pass for the wrong reason. Run on every platform.

    /// What the delegate answers for each redirect of one task: the new request's URL, or nil when refused.
    private func answers(_ delegate: BoundedRedirectDelegate, task: URLSessionTask, to locations: [String]) -> [String?] {
        locations.map { location in
            let current = task.currentRequest?.url ?? URL(string: "https://redirects.example/start")!
            let response = HTTPURLResponse(url: current, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            // A relative Location is resolved against the current address before the session asks.
            let target = URL(string: location, relativeTo: current)!.absoluteURL
            var answer: URLRequest?
            var asked = false
            delegate.urlSession(URLSession(configuration: .ephemeral), task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) {
                asked = true
                answer = $0
            }
            XCTAssertTrue(asked, "the delegate answers at once, whatever it decides")
            return answer?.url?.absoluteString
        }
    }

    /// Task identifiers are unique within a session, not across sessions, so every task here comes from one session.
    private static let taskSession = URLSession(configuration: .ephemeral)

    private func task() -> URLSessionTask {
        Self.taskSession.dataTask(with: URL(string: "https://redirects.example/hop/9")!)
    }

    func testTheAppSessionUsesTheBoundedRedirectDelegateWithALimitOfFive() {
        let session = FollowedSourceCoordinator.boundedSession(configuration: .ephemeral)

        let delegate = session.delegate as? BoundedRedirectDelegate

        XCTAssertNotNil(delegate, "the session the app makes is the one with the redirect rule")
        XCTAssertEqual(delegate?.maximumRedirects, 5)
    }

    func testFiveRedirectsAreFollowedAndASixthIsRefused() {
        let hops = (1...6).map { "https://redirects.example/hop/\($0)" }

        let results = answers(BoundedRedirectDelegate(maximumRedirects: 5), task: task(), to: hops)

        XCTAssertEqual(results, Array(hops.prefix(5)).map { Optional($0) } + [nil], "hops 1 to 5 are followed, hop 6 is refused")
    }

    func testTheRedirectCountIsPerTaskAndNeverResets() {
        let delegate = BoundedRedirectDelegate(maximumRedirects: 5)
        let first = task()
        let second = task()
        let hop = "https://redirects.example/next"

        XCTAssertEqual(answers(delegate, task: first, to: Array(repeating: hop, count: 6)).compactMap { $0 }.count, 5)
        XCTAssertNil(answers(delegate, task: first, to: [hop]).first!, "a refused task stays refused")
        XCTAssertEqual(answers(delegate, task: second, to: Array(repeating: hop, count: 6)).compactMap { $0 }.count, 5, "another task starts from zero")
    }

    func testNeighbouringChainLengthsAndTargets() {
        // (label, locations the server sends in order, what the delegate answers: true followed, false refused)
        let https = "https://redirects.example/hop/"
        let table: [(String, [String], [Bool])] = [
            ("four hops", (1...4).map { "\(https)\($0)" }, [true, true, true, true]),
            ("five hops", (1...5).map { "\(https)\($0)" }, [true, true, true, true, true]),
            ("six hops", (1...6).map { "\(https)\($0)" }, [true, true, true, true, true, false]),
            ("fifty hops", (1...50).map { "\(https)\($0)" }, Array(repeating: true, count: 5) + Array(repeating: false, count: 45)),
            ("a downgrade to http", ["http://redirects.example/feed.xml"], [false]),
            ("a downgrade after two https hops", ["\(https)1", "\(https)2", "http://redirects.example/feed.xml"], [true, true, false]),
            ("a redirect to another host", ["https://other.example/feed.xml"], [true]),
            ("a relative Location", ["/hop/1"], [true]),
            ("a relative Location with a query", ["hop/1?a=b"], [true]),
            ("an upper-case scheme", ["HTTPS://redirects.example/feed.xml"], [true]),
            ("a different scheme", ["ftp://redirects.example/feed.xml"], [false]),
            ("a scheme-less host", ["//other.example/feed.xml"], [true]),
        ]
        for (label, locations, expected) in table {
            let results = answers(BoundedRedirectDelegate(maximumRedirects: 5), task: task(), to: locations)
            XCTAssertEqual(results.map { $0 != nil }, expected, label)
        }
    }

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

    // MARK: Multilingual pages (#4640)

    /// openai.com lists 40-odd `hreflang` page alternates before any feed link. The first 8 alternates used to be taken
    /// before their type was checked, so the RSS link after them was never seen.
    func testAFeedLinkAfterManyLanguageAlternatesIsFound() async throws {
        let languages = (0..<40).map { #"<link rel="alternate" hreflang="l\#($0)" href="https://multilingual.example/l\#($0)/article">"# }.joined()
        let feedLink = #"<link rel="alternate" type="application/rss+xml" href="/news/rss.xml">"#
        DiscoveryStubProtocol.serve("https://multilingual.example/article",
            .html("<html><head><title>Article</title>\(languages)\(feedLink)</head><body><p>Text.</p></body></html>"))
        DiscoveryStubProtocol.serve("https://multilingual.example/news/rss.xml",
            .feed(rss(title: "News", links: ["https://multilingual.example/article"])))
        let coordinator = coordinator()

        let candidates = try await coordinator.discover(urlString: "https://multilingual.example/article")

        XCTAssertEqual(candidates.first?.source.canonicalURL, "https://multilingual.example/news/rss.xml")
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
