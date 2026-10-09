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
}
