import Foundation
import XCTest
import SessionKit
import SessionKitSharing

final class SharedArticleReferencePolicyTests: XCTestCase {
    private func item(_ type: SharedItemType = .text, url: String?) -> SharedItemIdentity {
        SharedItemIdentity(itemType: type, canonicalURL: url, originalURL: url, title: "An essay")
    }

    func testAnArticleWithAnHTTPSLinkIsFetchable() {
        XCTAssertEqual(
            SharedArticleReferencePolicy.articleURL(for: item(url: "https://Example.com/essays/slow-listening/#notes"))?.absoluteString,
            "https://example.com/essays/slow-listening"
        )
        XCTAssertEqual(
            SharedArticleReferencePolicy.articleURL(for: item(url: "https://example.com/read?id=7"))?.absoluteString,
            "https://example.com/read?id=7"
        )
    }

    func testNeighbouringItemsAreNotFetchedAsArticles() {
        for type in [SharedItemType.podcast, .pdf, .epub, .other] {
            XCTAssertNil(SharedArticleReferencePolicy.articleURL(for: item(type, url: "https://example.com/a")), "\(type)")
        }
        for link in [nil, "", " ", "http://example.com/a", "ftp://example.com/a", "file:///tmp/a.txt", "https://", "not a url", "javascript:alert(1)"] as [String?] {
            XCTAssertNil(SharedArticleReferencePolicy.articleURL(for: item(url: link)), link ?? "nil")
        }
    }

    func testAFetchedPageThatEndedElsewhereIsNotTheSharedArticle() {
        let shared = item(url: "https://news.example.com/story")
        let text = "The story text."
        // Same page, however the address was written.
        for landed in ["https://news.example.com/story", "https://NEWS.example.com/story/", "https://news.example.com/story#top"] {
            XCTAssertTrue(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(shared, fetchedURL: landed, fetchedText: text), landed)
        }
        // A consent wall, a sign-in page, another host, a different path or query, a downgraded scheme or no address.
        for landed in [
            "https://consent.yahoo.com/collectConsent?next=story",
            "https://news.example.com/login?next=/story",
            "https://m.news.example.com/story",
            "https://news.example.com/story?page=2",
            "http://news.example.com/story",
            "",
        ] {
            XCTAssertFalse(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(shared, fetchedURL: landed, fetchedText: "Before you continue"), landed)
        }
    }

    func testARedirectedPageWithThePacketsTextIsStillTheSharedArticle() {
        let text = "The story text, as the sender saw it."
        let shared = SharedItemIdentity(
            itemType: .text,
            canonicalURL: "https://news.example.com/story",
            title: "An essay",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text)
        )
        XCTAssertTrue(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(
            shared, fetchedURL: "https://m.news.example.com/story", fetchedText: text
        ))
        XCTAssertFalse(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(
            shared, fetchedURL: "https://m.news.example.com/story", fetchedText: "Before you continue"
        ))
    }
}
