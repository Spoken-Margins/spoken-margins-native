import Foundation
import XCTest
@testable import SessionKit

/// #144: an article link typed into Link or Podcast failed with "Article URLs must use HTTPS." on the owner's
/// phone. Any navigation inside a frame of the page (an embedded tweet or video, an ad, an `about:blank` frame)
/// ended the whole read, and https frames counted as redirects of the article.
final class ReadablePageNavigationRulesTests: XCTestCase {
    private let article = URL(string: "https://paulgraham.com/greatwork.html")!

    func testFramesInsideThePageAreSkippedAndTheReadCarriesOn() {
        var rules = ReadablePageNavigationRules(requestedURL: article)
        XCTAssertEqual(rules.decide(url: article, targetIsMainFrame: true, isRedirect: false), .load)

        let frames = [
            "about:blank",
            "http://ads.example.net/slot",
            "https://platform.twitter.com/embed/Tweet.html?id=1",
            "https://www.youtube.com/embed/abc",
        ]
        for frame in frames {
            XCTAssertEqual(
                rules.decide(url: URL(string: frame), targetIsMainFrame: false, isRedirect: true),
                .skipFrame,
                frame
            )
        }
        XCTAssertEqual(rules.decide(url: URL(string: "https://example.com/popup"), targetIsMainFrame: nil, isRedirect: false), .skipFrame)

        XCTAssertEqual(rules.contactedHosts, ["paulgraham.com"], "a skipped frame never loads, so its host isn't contacted")
        for step in 1...ReadablePageNavigationRules.maximumRedirects {
            let hop = URL(string: "https://paulgraham.com/hop\(step)")!
            XCTAssertEqual(rules.decide(url: hop, targetIsMainFrame: true, isRedirect: true), .load, "frames don't use up the page's redirects")
        }
    }

    func testThePageItselfLeavingHTTPSStillEndsTheRead() {
        var rules = ReadablePageNavigationRules(requestedURL: article)
        XCTAssertEqual(
            rules.decide(url: URL(string: "http://paulgraham.com/greatwork.html"), targetIsMainFrame: true, isRedirect: true),
            .refuse(.pageLeftHTTPS)
        )
    }

    func testThePageRedirectingTooOftenStillEndsTheRead() {
        var rules = ReadablePageNavigationRules(requestedURL: article)
        for step in 1...ReadablePageNavigationRules.maximumRedirects {
            XCTAssertEqual(rules.decide(url: URL(string: "https://a.example/\(step)"), targetIsMainFrame: true, isRedirect: true), .load)
        }
        XCTAssertEqual(
            rules.decide(url: URL(string: "https://a.example/last"), targetIsMainFrame: true, isRedirect: true),
            .refuse(.tooManyRedirects)
        )
        XCTAssertEqual(rules.contactedHosts, ["paulgraham.com", "a.example"])
    }
}
