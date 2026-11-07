import Foundation
import XCTest
@testable import SessionKit

/// #3548: a bare host name is the one thing the export's shape scrubbers cannot recognise, so the app stops
/// writing hosts into diagnostics. These tests fail if a host, a handle or a publisher name gets back in.
final class DiagnosticsHostRedactionTests: XCTestCase {
    func testHostCountNamesNoHost() {
        XCTAssertEqual(DiagnosticsHostRedaction.hostCount([String]()), "none")
        XCTAssertEqual(DiagnosticsHostRedaction.hostCount(["Example.com", "example.com"]), "1 host", "case-insensitive, distinct")
        XCTAssertEqual(DiagnosticsHostRedaction.hostCount(Set(["a.example", "b.example", "c.example"])), "3 hosts")
        XCTAssertEqual(DiagnosticsHostRedaction.hostCount([""]), "none", "an empty host is not a contacted host")
        for hosts in [["my-private-blog.example"], ["a.example", "my-private-blog.example"]] {
            XCTAssertFalse(DiagnosticsHostRedaction.hostCount(hosts).contains("blog"))
        }
    }

    func testProviderLabelKeepsResolverIdsAndHidesHosts() {
        // Our own resolver ids (PublicPodcastLinkResolver, the package importer) pass through.
        for id in ["spotify", "apple_podcasts", "direct_audio", "rss", "episode_page", "shared_package"] {
            XCTAssertEqual(DiagnosticsHostRedaction.providerLabel(id), id)
        }
        XCTAssertEqual(DiagnosticsHostRedaction.providerLabel(nil), "unknown")
        XCTAssertEqual(DiagnosticsHostRedaction.providerLabel(""), "unknown")
        // The metadata-only path passes `url.host` as the provider. Table of neighbouring shapes.
        let hosts = [
            "example.com", "www.example.com", "my-private-blog.example", "Example.COM", "blog.example.co.uk",
            "localhost:8080", "localhost", "intranet", "my_blog", "192.168.0.12", "xn--bcher-kva.example", "ex ample", "spotify.com",
            String(repeating: "a", count: 40),
        ]
        for host in hosts {
            XCTAssertEqual(DiagnosticsHostRedaction.providerLabel(host), "other_site", host)
        }
    }

    func testRedactingHostsTable() {
        let ph = DiagnosticsHostRedaction.hostPlaceholder
        let cases: [(String, String)] = [
            ("page on www.platformer.news: status 404", "page on \(ph): status 404"),
            ("page on Example.COM: status 200", "page on \(ph): status 200"),
            ("page on blog.example.co.uk: not served by Substack", "page on \(ph): not served by Substack"),
            ("page on my-private-blog.example:8443: status 500", "page on \(ph): status 500"),
            ("profile @someauthor: status 404", "profile \(ph): status 404"),
            ("profile @some.author-1_x: no primary publication", "profile \(ph): no primary publication"),
            ("feed on sub.example.substack.com: Substack feed, 20 items", "feed on \(ph): Substack feed, 20 items"),
            ("direct: not a feed (NSURLErrorDomain -1009) | generic: feed_noItems", "direct: not a feed (NSURLErrorDomain -1009) | generic: feed_noItems"),
            ("my-pub.substack.com/feed: status 404", "\(ph)/feed: status 404"),
            ("my_blog.example.com: status 404", "\(ph): status 404"),
            ("bücher.example: status 404", "\(ph): status 404"),
            ("page on 192.168.0.12:8080: status 500", "page on \(ph): status 500"),
            ("not an http(s) link", "not an http(s) link"),
            ("none", "none"),
            ("", ""),
            ("two hosts a.example and b.example in one line", "two hosts \(ph) and \(ph) in one line"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DiagnosticsHostRedaction.redactingHosts(in: input), expected, input)
        }
    }

    func testNoPublisherNameSurvivesRedaction() {
        let secrets = ["quietly-reading-about-grief.example", "janedoe", "my-private-blog"]
        let line = "substack: page on quietly-reading-about-grief.example: status 404 | profile @janedoe: no primary publication | feed on my-private-blog.substack.com: not Substack"
        let out = DiagnosticsHostRedaction.redactingHosts(in: line)
        for secret in secrets { XCTAssertFalse(out.contains(secret), "\(secret) leaked in: \(out)") }
    }
}
