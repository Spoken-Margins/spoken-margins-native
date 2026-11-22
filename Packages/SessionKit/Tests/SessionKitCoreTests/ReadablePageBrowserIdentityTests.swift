import Foundation
import XCTest
@testable import SessionKit

/// #4776: X answers an iPhone user agent with a hand-off to Safari (`302 x-safari-https://…`, recorded 2026-11-22)
/// and a Mac Safari one with the post's page. Only X's hosts change identity; no other site is touched.
final class ReadablePageBrowserIdentityTests: XCTestCase {
    func testXHostsReadAsMacSafari() {
        let hosts = [
            "https://x.com/jack/status/20",
            "https://X.COM/jack/status/20",
            "https://www.x.com/jack/status/20",
            "https://mobile.x.com/jack/status/20",
            "https://x.com./jack/status/20",
            "https://twitter.com/jack/status/20",
            "https://mobile.twitter.com/jack/status/20",
            "https://x.com:443/jack/status/20?s=46&t=abc",
        ]
        for host in hosts {
            XCTAssertEqual(ReadablePageBrowserIdentity.userAgent(for: URL(string: host)!), ReadablePageBrowserIdentity.macSafari, host)
        }
    }

    func testOtherSitesAndLookalikesKeepTheWebViewsOwnIdentity() {
        let others = [
            "https://paulgraham.com/greatwork.html",
            "https://www.macrumors.com/2026/11/20/ios-26-2/",
            "https://notx.com/a",
            "https://xx.com/a",
            "https://x.com.evil.example/a",
            "https://evil.example/x.com/status/1",
            "https://evil.example/?u=https://x.com/a",
            "https://t.co/abc123",
            "https://fxtwitter.com/jack/status/20",
            "https://twitter.com.example.org/a",
            "https://substack.com/@someone/note/c-1",
            "http://x.com/jack/status/20",
        ]
        for other in others {
            XCTAssertNil(ReadablePageBrowserIdentity.userAgent(for: URL(string: other)!), other)
        }
    }

    func testTheIdentityIsAMacSafariOneNotAnIPhoneOne() {
        let agent = ReadablePageBrowserIdentity.macSafari
        XCTAssertTrue(agent.contains("Macintosh"))
        XCTAssertTrue(agent.contains("Safari/"))
        XCTAssertFalse(agent.contains("iPhone"))
    }
}
