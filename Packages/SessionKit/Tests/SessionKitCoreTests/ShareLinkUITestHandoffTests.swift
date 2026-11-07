import XCTest
@testable import SessionKit

#if DEBUG
/// J10's share link step (#1842) reaches the app through this hand-off, because hosted simulators don't route
/// universal links. It must carry the link whole, key included, and carry nothing that isn't a share link.
final class ShareLinkUITestHandoffTests: XCTestCase {
    /// The link `J10OfflineJourneyUITests` opens; `ShareLinkOpeningTests` pins that it asks the server.
    private let j10Link = "https://spokenmargins.proximitytoprogress.com/l/0123456789abcdef0123456789abcdef#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    /// The exact string the UI test builds: the link percent-encoded with only letters and digits left bare.
    private func handoff(_ link: String) -> URL {
        URL(string: "spokenmargins://ui-test-share-link?url=" + link.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    func testJ10sHandoffOpensTheSameLinkWithItsKey() throws {
        let inner = try XCTUnwrap(ShareLinkUITestHandoff.shareLink(in: handoff(j10Link)))

        XCTAssertEqual(inner.absoluteString, j10Link)
        let link = try XCTUnwrap(ShareLinkURL(url: inner), "the handed-off link no longer parses as a share link")
        XCTAssertNotNil(link.key, "the key was lost on the way, so the link would fail as damaged, not offline")
    }

    func testTheBuilderAndTheUITestsStringAgree() throws {
        let link = try XCTUnwrap(URL(string: j10Link))
        XCTAssertEqual(ShareLinkUITestHandoff.url(carrying: link), handoff(j10Link))
    }

    func testEveryShareHostRoundTrips() throws {
        for host in ShareLinkURL.shareHosts {
            let text = "https://\(host)/l/0123456789abcdef0123456789abcdef#AAAA"
            XCTAssertEqual(ShareLinkUITestHandoff.shareLink(in: handoff(text))?.absoluteString, text, host)
        }
    }

    func testOnlyAShareLinkInAWellFormedHandoffComesOut() {
        let encodedLink = j10Link.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let refused: [(String, String)] = [
            ("another host on the app's scheme", "spokenmargins://listening-edition?url=\(encodedLink)"),
            ("another scheme", "https://ui-test-share-link?url=\(encodedLink)"),
            ("no url", "spokenmargins://ui-test-share-link"),
            ("an empty url", "spokenmargins://ui-test-share-link?url="),
            ("two urls", "spokenmargins://ui-test-share-link?url=\(encodedLink)&url=\(encodedLink)"),
            ("a key left outside the link", "spokenmargins://ui-test-share-link?url=https%3A%2F%2Fspokenmargins.com%2Fl%2F0123456789abcdef0123456789abcdef#AAAA"),
            ("a lookalike host", handoff("https://spokenmargins.com.example.net/l/0123456789abcdef0123456789abcdef#AAAA").absoluteString),
            ("a subdomain", handoff("https://www.spokenmargins.com/l/0123456789abcdef0123456789abcdef#AAAA").absoluteString),
            ("plain http", handoff("http://spokenmargins.com/l/0123456789abcdef0123456789abcdef#AAAA").absoluteString),
            ("a file", handoff("file:///tmp/friend.spokenmargins").absoluteString),
            ("another app scheme", handoff("spokenmargins://listening-edition?id=x").absoluteString),
        ]
        for (name, text) in refused {
            let url = URL(string: text)!
            XCTAssertNil(ShareLinkUITestHandoff.shareLink(in: url), name)
        }
    }

    func testTheSchemeAndHostIgnoreCase() {
        let encoded = j10Link.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = URL(string: "SpokenMargins://UI-Test-Share-Link?url=\(encoded)")!
        XCTAssertEqual(ShareLinkUITestHandoff.shareLink(in: url)?.absoluteString, j10Link)
    }
}
#endif
