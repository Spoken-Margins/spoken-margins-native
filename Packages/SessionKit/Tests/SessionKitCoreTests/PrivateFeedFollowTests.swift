import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4176: a paid show's private feed link (Patreon, Supercast, a path token) follows like any other feed, keeps its
/// token to its own host, and a feed that turns the link down says so instead of "did not return a supported feed".
/// Real storage behind the coordinator; only the transport is stubbed. Each test uses its own host.
///
/// The packet side is pinned in `PrivateFeedLinkTests` (SessionKitTests: a packet from a tokenized feed carries no
/// feed or enclosure address, and the share-link preview holds none either).
final class PrivateFeedFollowTests: XCTestCase {
    private static let refusedWords = "The feed turned this link down. Try again later, or for a paid show, copy a fresh RSS link from the creator\u{2019}s page."

    override func setUp() {
        super.setUp()
        PrivateFeedStubProtocol.reset()
    }

    private func coordinator(_ repository: InMemorySessionRepository = InMemorySessionRepository()) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivateFeedStubProtocol.self]
        return FollowedSourceCoordinator(
            repository: repository,
            session: FollowedSourceCoordinator.boundedSession(configuration: configuration),
            signals: nil
        )
    }

    private func rss(title: String, enclosure: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>\(title)</title><link>https://example.com</link>
        <item><title>Episode one</title><guid>episode-one</guid><enclosure url="\(enclosure.replacingOccurrences(of: "&", with: "&amp;"))" type="audio/mpeg" length="1000"/></item>
        </channel></rss>
        """.utf8)
    }

    // MARK: A tokenized link follows like any other

    func testAPatreonStyleLinkIsRequestedWithItsQueryIntactFollowedAndStored() async throws {
        let link = "https://www.patreon.com/rss/fixture?auth=TOKEN123"
        let enclosure = "https://c10.patreonusercontent.com/audio/one.mp3?token-time=1&token-hash=SECRETHASH"
        PrivateFeedStubProtocol.serve(link, status: 200, body: rss(title: "Paid Show", enclosure: enclosure))
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)

        let subscription = try await coordinator.follow(urlString: link)

        XCTAssertEqual(subscription.source.canonicalURL, link, "the address is stored as pasted, token included")
        XCTAssertEqual(try repository.loadFeedSubscriptions().map(\.source.canonicalURL), [link])
        XCTAssertEqual(Set(PrivateFeedStubProtocol.requests(host: "www.patreon.com")), [link], "only the pasted address, query intact, never a probe")
        let entries = try await coordinator.entries()
        XCTAssertEqual(entries.map(\.audioURL), [enclosure], "the episode keeps its tokenized audio address")
    }

    func testAPathTokenLinkOnAnotherHostBehavesTheSame() async throws {
        let link = "https://feeds.paidshow.example/private/9f8e7d6c5b4a39281706f5e4d3c2b1a0.rss"
        PrivateFeedStubProtocol.serve(link, status: 200, body: rss(title: "Path Token Show", enclosure: "https://media.paidshow.example/one.mp3"))
        let repository = InMemorySessionRepository()

        let subscription = try await coordinator(repository).follow(urlString: link)

        XCTAssertEqual(subscription.source.canonicalURL, link)
        XCTAssertEqual(try repository.loadFeedSubscriptions().count, 1)
        XCTAssertEqual(Set(PrivateFeedStubProtocol.requests(host: "feeds.paidshow.example")), [link])
    }

    func testFollowingTheSameTokenizedAddressTwiceKeepsOneFollow() async throws {
        let link = "https://www.supercast.com/rss/twice?token=ABC"
        PrivateFeedStubProtocol.serve(link, status: 200, body: rss(title: "Twice", enclosure: "https://media.supercast.example/one.mp3"))
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)

        let first = try await coordinator.followFeed(urlString: link)
        let second = try await coordinator.followFeed(urlString: link)

        XCTAssertEqual(second.id, first.id, "the second paste finds the follow it already has")
        XCTAssertEqual(try repository.loadFeedSubscriptions().count, 1)
    }

    // MARK: A refusal says so, and sends the token once

    func testA401Or403OnAPaidShowLinkIsRefusedAfterOneRequestAndSavesNothing() async throws {
        for (status, host) in [(401, "www.patreon.com"), (403, "www.supercast.com")] {
            PrivateFeedStubProtocol.reset()
            let link = "https://\(host)/rss/fixture?auth=TOKEN\(status)"
            PrivateFeedStubProtocol.serve(link, status: status, body: Data("denied".utf8))
            let repository = InMemorySessionRepository()
            let coordinator = coordinator(repository)

            let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: link) }

            guard case FollowedSourceError.refused = error else { return XCTFail("\(status) gave \(error)") }
            XCTAssertEqual(error.localizedDescription, Self.refusedWords)
            XCTAssertEqual(FollowedSourceCoordinator.diagnosticCode(for: error), "refused")
            XCTAssertEqual(PrivateFeedStubProtocol.requests(host: host), [link],
                           "\(status): the token goes out once; no Substack lookup, no second request, no /feed or /rss probe")
            XCTAssertEqual(try repository.loadFeedSubscriptions().count, 0, "\(status): nothing is saved")
            let entries = try await coordinator.entries()
            XCTAssertEqual(entries.count, 0)
        }
    }

    func testARefusedPathTokenLinkOnAnotherHostIsRefusedWithoutHTMLDiscovery() async throws {
        for status in [401, 403] {
            PrivateFeedStubProtocol.reset()
            let host = "feeds.refused\(status).example"
            let link = "https://\(host)/private/9f8e7d6c5b4a39281706f5e4d3c2b1a0.rss"
            PrivateFeedStubProtocol.serve(link, status: status, body: Data())
            let coordinator = coordinator()

            let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: link) }

            guard case FollowedSourceError.refused = error else { return XCTFail("\(status) gave \(error)") }
            let asked = PrivateFeedStubProtocol.requests(host: host)
            XCTAssertEqual(asked.filter { $0 == link }.count, 2, "\(status): the direct fetch and Substack's one page check, not HTML discovery's third: \(asked)")
            for guess in ["/feed.xml", "/rss", "/atom.xml"] {
                XCTAssertFalse(asked.contains("https://\(host)\(guess)"), "\(status): no same-origin guess \(guess)")
            }
        }
    }

    func testTheFailureDiagnosticAfterARefusalHoldsNeitherTheTokenNorTheHost() async throws {
        let link = "https://diag.example/rss/fixture?auth=SECRETTOKEN"
        PrivateFeedStubProtocol.serve(link, status: 403, body: Data())
        let coordinator = coordinator()

        let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: link) }
        let line = await coordinator.failureDiagnostic(for: error)

        XCTAssertTrue(line.hasPrefix("refused host="), line)
        XCTAssertTrue(line.contains("direct: not a feed (refused)"), line)
        XCTAssertFalse(line.contains("SECRETTOKEN"), line)
        XCTAssertFalse(line.contains("diag.example"), line)
    }

    func testTheNeighbouringStatusesKeepTheirOldMeaning() async throws {
        // Only 401 and 403 are a refusal; every other failing status still reads as "not a supported feed".
        for status in [400, 404, 410, 429, 500, 503] {
            let host = "status\(status).example"
            let link = "https://\(host)/feed.xml"
            PrivateFeedStubProtocol.serve(link, status: status, body: Data())
            let coordinator = coordinator()

            let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: link) }

            XCTAssertEqual(FollowedSourceCoordinator.diagnosticCode(for: error), "invalid_response", "status \(status)")
        }
    }

    func testARefusedSubstackPostPageStillReachesSubstacksLookupAndThenIsRefused() async throws {
        let host = "refusedpub.substack.com"
        // A long slug reads as a secret to the sharing policy; it is a post, and Substack's lookup must still run.
        let link = "https://\(host)/p/the-2024-guide-to-writing-newsletters-that-people-read"
        PrivateFeedStubProtocol.serve(link, status: 403, body: Data())
        let coordinator = coordinator()

        let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: link) }

        guard case FollowedSourceError.refused = error else { return XCTFail("gave \(error)") }
        let asked = PrivateFeedStubProtocol.requests(host: host)
        XCTAssertTrue(asked.contains("https://\(host)/feed"), "a post page that refuses a direct read still gets Substack's lookup: \(asked)")
        XCTAssertFalse(asked.contains("https://\(host)/rss"), "but not the same-origin guesses of HTML discovery: \(asked)")
        XCTAssertEqual(asked.filter { $0 == link }.count, 2, "the direct fetch and Substack's page check, and no third from HTML discovery: \(asked)")
    }

    func testAPageLinkThatIsRefusedIsRefusedToo() async throws {
        let host = "page403.example"
        let link = "https://\(host)/articles/one"
        PrivateFeedStubProtocol.serve(link, status: 403, body: Data())
        let coordinator = coordinator()

        let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: link) }

        guard case FollowedSourceError.refused = error else { return XCTFail("gave \(error)") }
        let asked = PrivateFeedStubProtocol.requests(host: host)
        XCTAssertEqual(asked.filter { $0 == link }.count, 2, "the direct fetch and Substack's page check; HTML discovery adds none: \(asked)")
        XCTAssertFalse(asked.contains("https://\(host)/rss"), "no same-origin guesses: \(asked)")
    }

    func testAWebPageWithNoFeedStillSaysSo() async throws {
        let host = "nofeed403free.example"
        PrivateFeedStubProtocol.serve("https://\(host)/page", status: 200, contentType: "text/html", body: Data("<html><body>No feed here</body></html>".utf8))
        let coordinator = coordinator()

        let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: "https://\(host)/page") }

        XCTAssertEqual(FollowedSourceCoordinator.diagnosticCode(for: error), "no_feed_candidates")
        XCTAssertEqual(error.localizedDescription, "This website doesn't offer a feed Spoken Margins can follow.")
    }

    func testAnHTTPLinkIsStillNeverRequestedOverHTTP() async throws {
        let coordinator = coordinator()

        let error = try await XCTUnwrapAsyncError { _ = try await coordinator.follow(urlString: "http://plainhttp.example/rss?auth=TOKEN") }

        XCTAssertEqual(FollowedSourceCoordinator.diagnosticCode(for: error), "insecure_url")
        let asked = PrivateFeedStubProtocol.requests(host: "plainhttp.example")
        XCTAssertFalse(asked.contains { $0.hasPrefix("http://") }, "the token never crosses the network in the clear: \(asked)")
    }

    // MARK: A private feed stays out of an OPML export

    func testAFollowedTokenizedFeedIsWithheldFromOPMLAndCounted() async throws {
        let privateLink = "https://www.patreon.com/rss/opml-private?auth=OPMLTOKEN"
        let publicLink = "https://opml-public.example/feed.xml"
        PrivateFeedStubProtocol.serve(privateLink, status: 200, body: rss(title: "Private Show", enclosure: "https://media.patreon.example/one.mp3"))
        PrivateFeedStubProtocol.serve(publicLink, status: 200, body: rss(title: "Public Show", enclosure: "https://media.public.example/one.mp3"))
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        _ = try await coordinator.follow(urlString: privateLink)
        _ = try await coordinator.follow(urlString: publicLink)

        let export = OPMLExporter.export(try repository.loadFeedSubscriptions())
        let text = String(decoding: export.data, as: UTF8.self)

        XCTAssertEqual(export.exportedCount, 1)
        XCTAssertEqual(export.withheldPrivateCount, 1)
        XCTAssertTrue(text.contains(publicLink), text)
        XCTAssertFalse(text.contains("OPMLTOKEN"), text)
        XCTAssertFalse(text.contains("Private Show"), "everything attached to a private feed is left out too")
    }

    // MARK: What the Follow sheet says (Design PR 2)

    /// The sheet's footer is where a listener with a paid show learns the link works and where to find it. Its exact
    /// words are the Design's, and #5094 gives the web Follow sheet the same line (not enforced across the two).
    func testTheFollowSheetFooterSaysAPaidShowsPrivateLinkComesFromTheCreatorsPage() {
        XCTAssertEqual(
            FollowPasteDecision.sheetFooter,
            "Or type a show\u{2019}s feed link. For a paid show, such as one on Patreon, copy your private RSS link from the creator\u{2019}s page.")
        XCTAssertFalse(FollowPasteDecision.sheetFooter.contains("podcast app"), "members find the link on the creator's page, not in a podcast app")
        XCTAssertFalse(FollowPasteDecision.sheetFooter.contains("'"), "typographic apostrophes only")
    }

    /// The sheet shows a failed follow through `ListenerErrorText.message(for:)` (`Gate1AppModel+FollowFromLink`). The
    /// refused sentence must come through whole, not as the generic "Something went wrong" line.
    func testARefusalReachesTheFollowSheetInItsOwnWords() async throws {
        let link = "https://www.patreon.com/rss/sheet-refused?auth=SHEETTOKEN"
        PrivateFeedStubProtocol.serve(link, status: 403, body: Data("denied".utf8))
        let error = try await XCTUnwrapAsyncError {
            _ = try await self.coordinator(InMemorySessionRepository()).follow(urlString: link)
        }

        let line = ListenerErrorText.message(for: error)
        XCTAssertEqual(line, Self.refusedWords)
        XCTAssertFalse(line.contains("SHEETTOKEN"), "the token is never repeated back")
        XCTAssertFalse(line.contains("patreon.com"), "nor the host")
    }

    // MARK: Helpers

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

/// Serves what each test registers, by full URL including the query; anything else is a 404. Keeps every URL asked.
private final class PrivateFeedStubProtocol: URLProtocol, @unchecked Sendable {
    private struct Reply {
        var status: Int
        var contentType: String
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var asked: [String] = []

    static func serve(_ url: String, status: Int, contentType: String = "application/rss+xml", body: Data) {
        lock.withLock { replies[url] = Reply(status: status, contentType: contentType, body: body) }
    }

    static func reset() {
        lock.withLock { asked = [] }
    }

    static func requests(host: String) -> [String] {
        lock.withLock { asked.filter { URL(string: $0)?.host?.lowercased() == host } }
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
        let served = reply ?? Reply(status: 404, contentType: "text/plain", body: Data())
        let response = HTTPURLResponse(url: url, statusCode: served.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": served.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: served.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
