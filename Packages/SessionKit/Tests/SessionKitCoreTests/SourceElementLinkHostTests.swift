import XCTest
@testable import SessionKit

/// #4778: a link row's kind line names where it goes ("Link · x.com"). Neighbouring inputs, so a lookalike host or a
/// link with no host can't print something wrong.
final class SourceElementLinkHostTests: XCTestCase {
    func testLinkHostTable() {
        let table: [(String, String?)] = [
            ("https://www.x.com/a", "x.com"),
            ("https://WWW.Example.com", "example.com"),
            ("https://x.com:8443/p", "x.com"),
            ("https://sub.www.example.com", "sub.www.example.com"),
            ("https://www.", "www."),
            ("https://192.168.0.1/x", "192.168.0.1"),
            ("mailto:a@b.c", nil),
            ("/relative/path", nil),
            ("", nil),
        ]
        for (url, expected) in table {
            XCTAssertEqual(link(url).timelineLinkHost, expected, url)
        }
    }

    func testAnInternationalHostKeepsAHostWithoutItsWWW() {
        // Punycode or Unicode depends on the OS, so only the shape is pinned.
        let host = link("https://www.bücher.de").timelineLinkHost
        XCTAssertNotNil(host)
        XCTAssertFalse(host?.hasPrefix("www.") ?? true, host ?? "nil")
    }

    func testOnlyLinksHaveAHost() {
        for kind in [SourceElement.Kind.picture, .embed, .table] {
            let element = SourceElement(id: "e", kind: kind, start: 0, label: "x", url: "https://www.x.com/p.png")
            XCTAssertNil(element.timelineLinkHost, kind.rawValue)
        }
    }

    private func link(_ url: String) -> SourceElement {
        SourceElement(id: "l", kind: .link, start: 0, label: "Link", url: url)
    }
}
