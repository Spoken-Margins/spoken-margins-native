import XCTest
@testable import SessionKit

/// #1167: "Open Original Source" on the Item screen offers a page address only for an item added by
/// link, and never a link that may carry a private-feed secret.
final class OriginalSourceLinkTests: XCTestCase {
    private func url(_ reference: String?, _ type: String? = "url") -> String? {
        OriginalSourceLink.url(externalReference: reference, externalReferenceType: type)?.absoluteString
    }

    func testPublicWebPagesAreOffered() {
        XCTAssertEqual(url("https://example.com/essay"), "https://example.com/essay")
        XCTAssertEqual(url("http://example.com/essay"), "http://example.com/essay")
        XCTAssertEqual(url("HTTPS://Example.com/Essay"), "HTTPS://Example.com/Essay")
        XCTAssertEqual(url("  https://example.com/essay \n"), "https://example.com/essay")
        XCTAssertEqual(url("https://example.com/a%20b?page=2#section-2"), "https://example.com/a%20b?page=2#section-2")
        XCTAssertEqual(url("https://www.e-flux.com/architecture/artificial-labor/140680/promethean-labors-and-domestic-realism"),
                       "https://www.e-flux.com/architecture/artificial-labor/140680/promethean-labors-and-domestic-realism")
    }

    func testNothingIsOfferedWithoutAPublicWebAddress() {
        let rows: [(String?, String)] = [
            (nil, "no reference"),
            ("", "empty"),
            ("   ", "blank"),
            ("/var/mobile/Containers/Data/Application/ABC/Documents/book.epub", "a file path"),
            ("file:///var/mobile/Documents/book.pdf", "a file URL"),
            ("manual-import", "the manual import label"),
            ("shared-package:abc", "a shared packet label"),
            ("bundled://guided-onboarding.v1", "the bundled guide"),
            ("javascript:alert(1)", "javascript"),
            ("data:text/html,hello", "data"),
            ("spokenmargins://open", "a custom scheme"),
            ("ftp://example.com/file", "ftp"),
            ("https.example.com/x", "a lookalike with no scheme"),
            ("example.com/x", "no scheme"),
            ("https://", "no host"),
            ("https://user:pass@example.com/x", "user info"),
            ("https://user@example.com/x", "a user name")
        ]
        for (reference, why) in rows {
            XCTAssertNil(url(reference), why)
        }
    }

    func testOnlyItemsAddedByLinkAreOffered() {
        for type in [nil, "", "file", "manual", "epub", "audiobook", "spoken_margins_package", "guided_onboarding", "URL", " url"] as [String?] {
            XCTAssertNil(url("https://example.com/essay", type), "type \(type ?? "nil")")
        }
    }

    func testLinksThatMayCarryAPrivateFeedSecretAreNotOffered() {
        let rows = [
            "https://www.patreon.com/rss/show?auth=abcdef0123456789",
            "https://feeds.supercast.com/podcasts/123/abc",
            "https://example.com/feed?token=abc",
            "https://example.com/private/feed.rss",
            "https://example.com/members/episode",
            "https://example.com/x?key=abc",
            "https://example.com/abcdefghijklmnopqrstuvwxyz0123456789ABCD",
            "https://example.com/a#token=abc"
        ]
        for reference in rows {
            XCTAssertNil(ShareableLinkPolicy.shareableLink(reference), "the link policy itself refuses \(reference)")
            XCTAssertNil(url(reference), reference)
        }
    }
}
