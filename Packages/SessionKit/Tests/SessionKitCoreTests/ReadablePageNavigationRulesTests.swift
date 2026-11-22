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

    /// #4776: an X post link failed with "the page moved to an address that isn't secure". Recorded 2026-11-22:
    /// `GET https://x.com/jack/status/20` with an iPhone user agent answers `302` with
    /// `location: x-safari-https://redirect.x.com/jack/status/20?ct=rw-null` (X handing an in-app browser over to
    /// Safari). That address is no web address and isn't insecure either, so it gets its own refusal; a real `http`
    /// downgrade is still the insecure one.
    func testAnotherAppsAddressIsNotCalledInsecure() {
        let post = URL(string: "https://x.com/jack/status/20")!
        var rules = ReadablePageNavigationRules(requestedURL: post)
        XCTAssertEqual(rules.decide(url: post, targetIsMainFrame: true, isRedirect: false), .load)
        XCTAssertEqual(
            rules.decide(url: URL(string: "x-safari-https://redirect.x.com/jack/status/20?ct=rw-null"), targetIsMainFrame: true, isRedirect: true),
            .refuse(.handedToAnotherApp)
        )
    }

    func testTableOfNeighbouringAddressesForThePageItself() {
        let table: [(String, ReadablePageNavigationRules.Decision)] = [
            ("x-safari-https://redirect.x.com/jack/status/20", .refuse(.handedToAnotherApp)),
            ("X-Safari-HTTPS://redirect.x.com/jack/status/20", .refuse(.handedToAnotherApp)),
            ("x-safari-http://redirect.x.com/a", .refuse(.handedToAnotherApp)),
            ("twitter://status?id=20", .refuse(.handedToAnotherApp)),
            ("itms-apps://apps.apple.com/app/id333903271", .refuse(.handedToAnotherApp)),
            ("mailto:someone@example.com", .refuse(.handedToAnotherApp)),
            ("https://x.com/i/flow/login", .load),
            ("HTTPS://X.COM/jack/status/20", .load),
            // A real downgrade stays the insecure refusal, and so does everything that isn't an app hand-off.
            ("http://x.com/jack/status/20", .refuse(.pageLeftHTTPS)),
            ("HTTP://x.com/jack/status/20", .refuse(.pageLeftHTTPS)),
            ("about:blank", .refuse(.pageLeftHTTPS)),
            ("data:text/html,hi", .refuse(.pageLeftHTTPS)),
            ("blob:https://x.com/1234", .refuse(.pageLeftHTTPS)),
            ("file:///etc/hosts", .refuse(.pageLeftHTTPS)),
            ("ftp://x.com/a", .refuse(.pageLeftHTTPS)),
            ("wss://x.com/socket", .refuse(.pageLeftHTTPS)),
            ("https:///no-host", .refuse(.pageLeftHTTPS)),
        ]
        for (address, expected) in table {
            var rules = ReadablePageNavigationRules(requestedURL: URL(string: "https://x.com/jack/status/20")!)
            XCTAssertEqual(rules.decide(url: URL(string: address), targetIsMainFrame: true, isRedirect: true), expected, address)
        }
        var rules = ReadablePageNavigationRules(requestedURL: URL(string: "https://x.com/jack/status/20")!)
        XCTAssertEqual(rules.decide(url: nil, targetIsMainFrame: true, isRedirect: true), .refuse(.pageLeftHTTPS))
    }

    func testAnotherAppsAddressInsideAFrameIsStillOnlySkipped() {
        var rules = ReadablePageNavigationRules(requestedURL: article)
        XCTAssertEqual(
            rules.decide(url: URL(string: "twitter://status?id=20"), targetIsMainFrame: false, isRedirect: true),
            .skipFrame
        )
        XCTAssertEqual(
            rules.decide(url: URL(string: "x-safari-https://redirect.x.com/a"), targetIsMainFrame: nil, isRedirect: false),
            .skipFrame
        )
    }
}
