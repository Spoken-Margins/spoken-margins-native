import Foundation
import XCTest
@testable import SessionKit

/// #4633: a link copied from X is a t.co address. The article reader loaded it in a web view, where t.co answers
/// with a small page of its own that has no article text, and the listener was told "no article text was found".
/// The shortener is now followed first, and the article is read from where it points.
final class ShortLinkFollowingTests: XCTestCase {
    private let shortLink = URL(string: "https://t.co/AbC123xyz")!
    private let article = URL(string: "https://example.com/essays/great-work?utm_source=x")!

    // MARK: Which addresses are shorteners

    func testOnlyHTTPSAddressesOnListedShortenersAreFollowed() {
        let cases: [(String, Bool)] = [
            ("https://t.co/AbC123", true),
            ("https://T.CO/AbC123", true),
            ("https://bit.ly/3xyz", true),
            ("https://example.com/essays/great-work", false),
            ("https://t.co.evil.example/AbC123", false),
            ("https://not-t.co/AbC123", false),
            ("https://x.com/ann/status/1", false),
            ("http://t.co/AbC123", false),
            ("ftp://t.co/AbC123", false),
            ("https://t.co", true),
        ]
        for (address, expected) in cases {
            XCTAssertEqual(ShortLink.isShortLink(URL(string: address)!), expected, address)
        }
    }

    // MARK: Following

    func testAPlainRedirectIsFollowedToTheArticle() async {
        let server = Server([shortLink: .redirect(article)])
        let resolved = await server.resolver.resolve(shortLink)
        XCTAssertEqual(resolved.url, article)
        XCTAssertEqual(resolved.followed, ["t.co"])
        XCTAssertEqual(server.asked, [shortLink])
    }

    func testAShortenersOwnPageIsFollowedByItsMetaRefresh() async {
        let page = #"<head><meta name="referrer" content="always"><noscript><META http-equiv="refresh" content="0;URL=https://example.com/essays/great-work?utm_source=x"></noscript><title>https://example.com/essays/great-work?utm_source=x</title></head>"#
        let server = Server([shortLink: .page(page)])
        let resolved = await server.resolver.resolve(shortLink)
        XCTAssertEqual(resolved.url, article)
    }

    func testAShortenersOwnPageIsFollowedByItsScriptRedirect() async {
        let page = #"<title>x</title><script>window.opener = null; location.replace("https:\/\/example.com\/essays\/great-work?utm_source=x")</script>"#
        let server = Server([shortLink: .page(page)])
        let resolved = await server.resolver.resolve(shortLink)
        XCTAssertEqual(resolved.url, article)
    }

    func testSeveralShortenersInARowAreFollowedAndTheArticleIsNotAskedFor() async {
        let second = URL(string: "https://bit.ly/second")!
        let server = Server([shortLink: .redirect(second), second: .redirect(article)])
        let resolved = await server.resolver.resolve(shortLink)
        XCTAssertEqual(resolved.url, article)
        XCTAssertEqual(resolved.followed, ["t.co", "bit.ly"])
        XCTAssertEqual(server.asked, [shortLink, second], "the shortener is asked, the publisher's page is not")
    }

    // MARK: Bounds and failures

    func testAChainOfShortenersStopsAtFiveHops() async {
        var table: [URL: Server.Answer] = [:]
        var hops = [shortLink]
        for step in 1...8 { hops.append(URL(string: "https://t.co/hop\(step)")!) }
        for (from, to) in zip(hops, hops.dropFirst()) { table[from] = .redirect(to) }
        let server = Server(table)
        let resolved = await server.resolver.resolve(shortLink)
        XCTAssertEqual(server.asked.count, ShortLinkResolver.maximumHops)
        XCTAssertEqual(resolved.url, hops[ShortLinkResolver.maximumHops], "it stops on the last address it reached")
    }

    func testADestinationThatIsNotHTTPSIsNeverFollowed() async {
        let cases: [(String, URL)] = [
            ("plain http", URL(string: "http://example.com/essay")!),
            ("a file", URL(string: "file:///etc/passwd")!),
            ("a custom scheme", URL(string: "spokenmargins://open")!),
            ("javascript", URL(string: "javascript:alert(1)")!),
        ]
        for (name, destination) in cases {
            let server = Server([shortLink: .redirect(destination)])
            let resolved = await server.resolver.resolve(shortLink)
            XCTAssertEqual(resolved.url, shortLink, name)
        }
        let page = #"<meta http-equiv="refresh" content="0;URL=http://example.com/essay">"#
        let resolved = await Server([shortLink: .page(page)]).resolver.resolve(shortLink)
        XCTAssertEqual(resolved.url, shortLink, "a page that names an http address is left to the reader's own https check")
    }

    func testFailuresLeaveTheAddressForTheReaderToMeet() async {
        let cases: [(String, Server.Answer)] = [
            ("offline", .failure),
            ("not found", .status(404)),
            ("server error", .status(500)),
            ("a 200 page with no redirect", .page("<html><body>Hello</body></html>")),
            ("an empty 200 page", .page("")),
            ("a 301 with no Location", .status(301)),
        ]
        for (name, answer) in cases {
            let resolved = await Server([shortLink: answer]).resolver.resolve(shortLink)
            XCTAssertEqual(resolved.url, shortLink, name)
        }
    }

    func testARedirectToItselfStopsAtOnce() async {
        let server = Server([shortLink: .redirect(shortLink)])
        let resolved = await server.resolver.resolve(shortLink)
        XCTAssertEqual(resolved.url, shortLink)
        XCTAssertEqual(server.asked.count, 1)
    }

    func testAnOrdinaryArticleAddressIsNeverRequested() async {
        let server = Server([:])
        let resolved = await server.resolver.resolve(article)
        XCTAssertEqual(resolved.url, article)
        XCTAssertEqual(resolved.followed, [])
        XCTAssertEqual(server.asked, [], "nothing is fetched for a link that isn't a shortener's")
    }

    // MARK: Interstitial parsing: neighbouring inputs

    func testInterstitialRedirectIsReadFromTheMarkupFormsShortenersUse() {
        let destination = "https://example.com/a?x=1&y=2"
        let cases: [(String, String)] = [
            ("meta, lower case", #"<meta http-equiv="refresh" content="0;url=https://example.com/a?x=1&y=2">"#),
            ("meta, upper case", #"<META HTTP-EQUIV="REFRESH" CONTENT="0; URL=https://example.com/a?x=1&y=2">"#),
            ("meta, entity-escaped ampersand", #"<meta http-equiv="refresh" content="0;URL=https://example.com/a?x=1&amp;y=2">"#),
            ("meta, single quotes", "<meta http-equiv='refresh' content='0;URL=https://example.com/a?x=1&y=2'>"),
            ("meta, content before http-equiv", #"<meta content="0;URL=https://example.com/a?x=1&y=2" http-equiv="refresh">"#),
            ("replace, escaped slashes", #"<script>location.replace("https:\/\/example.com\/a?x=1&y=2")</script>"#),
            ("replace, JSON-escaped ampersand", #"<script>location.replace("https:\/\/example.com\/a?x=1\u0026y=2")</script>"#),
            ("replace, spaces", #"<script>location.replace( 'https://example.com/a?x=1&y=2' );</script>"#),
            ("assign to href", #"<script>window.location.href = "https://example.com/a?x=1&y=2";</script>"#),
            ("multi-line page", "<head>\n<noscript>\n<meta http-equiv=\"refresh\"\n content=\"0;URL=https://example.com/a?x=1&y=2\">\n</noscript></head>"),
        ]
        for (name, html) in cases {
            XCTAssertEqual(
                ShortLink.destination(fromInterstitial: html, base: shortLink)?.absoluteString, destination, name)
        }
    }

    func testInterstitialWithNoUsableDestinationGivesNil() {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("plain page", "<html><body>Hello</body></html>"),
            ("refresh with no address", #"<meta http-equiv="refresh" content="30">"#),
            ("a comparison, not an assignment", #"<script>if (location.href == "https://example.com/a") {}</script>"#),
            ("http address", #"<meta http-equiv="refresh" content="0;URL=http://example.com/a">"#),
            ("a name that only ends in location", #"<script>relocation = "https://example.com/a"</script>"#),
            ("javascript address", #"<script>location.replace("javascript:alert(1)")</script>"#),
        ]
        for (name, html) in cases {
            XCTAssertNil(ShortLink.destination(fromInterstitial: html, base: shortLink), name)
        }
    }

    // MARK: The extractor that reads from the destination

    @MainActor
    func testTheArticleIsReadFromTheDestinationAndTheItemNamesIt() async throws {
        let inner = RecordingExtractor()
        let extractor = ShortLinkFollowingExtractor(
            wrapping: inner, resolver: Server([shortLink: .redirect(article)]).resolver)
        let handoff = try await extractor.extract(url: shortLink)
        XCTAssertEqual(inner.requested, [article], "the reader never sees the shortener's address")
        XCTAssertEqual(handoff.source.url, article.absoluteString, "the item names the destination, not t.co")
        XCTAssertEqual(extractor.contactedHosts, ["t.co", "example.com"])
        XCTAssertEqual(extractor.lastExtractor, "stub")
    }

    @MainActor
    func testADirectLinkAndItsShortLinkImportTheSameItem() async throws {
        let inner = RecordingExtractor()
        let extractor = ShortLinkFollowingExtractor(
            wrapping: inner, resolver: Server([shortLink: .redirect(article)]).resolver)
        let viaShortLink = try await extractor.extract(url: shortLink)
        let direct = try await extractor.extract(url: article)
        XCTAssertEqual(viaShortLink.source.url, direct.source.url, "the clipboard and the Safari share sheet converge")
        XCTAssertEqual(extractor.contactedHosts, ["example.com"], "a direct link asks no shortener")
    }

    @MainActor
    func testAnUnfollowableShortLinkIsStillHandedToTheReaderAsGiven() async throws {
        let inner = RecordingExtractor()
        let extractor = ShortLinkFollowingExtractor(wrapping: inner, resolver: Server([shortLink: .failure]).resolver)
        _ = try await extractor.extract(url: shortLink)
        XCTAssertEqual(inner.requested, [shortLink], "the reader's own errors and the Open in Safari offer still apply")
    }

    @MainActor
    func testTheReadersErrorsPassThroughUnchanged() async {
        struct Refused: Error, Equatable {}
        let inner = RecordingExtractor(failure: Refused())
        let extractor = ShortLinkFollowingExtractor(
            wrapping: inner, resolver: Server([shortLink: .redirect(article)]).resolver)
        do {
            _ = try await extractor.extract(url: shortLink)
            XCTFail("expected the reader's error")
        } catch {
            XCTAssertEqual(error as? Refused, Refused())
        }
    }
}

/// A table of canned answers by address, in place of the network.
private final class Server: @unchecked Sendable {
    enum Answer {
        case redirect(URL)
        case page(String)
        case status(Int)
        case failure
    }

    private let lock = NSLock()
    private let table: [URL: Answer]
    private var requests: [URL] = []

    init(_ table: [URL: Answer]) { self.table = table }

    var asked: [URL] { lock.withLock { requests } }

    var resolver: ShortLinkResolver {
        ShortLinkResolver { [self] url in
            lock.withLock { requests.append(url) }
            switch table[url] {
            case .redirect(let location): return ShortLinkHop(status: 301, location: location)
            case .page(let body): return ShortLinkHop(status: 200, bodyPrefix: body)
            case .status(let status): return ShortLinkHop(status: status)
            case .failure, nil: throw URLError(.notConnectedToInternet)
            }
        }
    }
}

@MainActor
private final class RecordingExtractor: ReadablePageExtracting {
    private let failure: (any Error)?
    private(set) var requested: [URL] = []
    private(set) var lastExtractor: String?
    private(set) var contactedHosts: [String] = []

    init(failure: (any Error)? = nil) { self.failure = failure }

    func extract(url: URL) async throws -> BrowserTextHandoff {
        requested.append(url)
        contactedHosts = [url.host ?? ""]
        if let failure { throw failure }
        lastExtractor = "stub"
        return BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: url.absoluteString, title: "The article"),
            text: "Body text.",
            contentFormat: .markdown
        )
    }
}
