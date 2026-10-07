import XCTest
@testable import SessionKit

/// ShareableLinkPolicy keeps a paid-feed link out of a shared packet, Markdown export, share link and log.
/// A leaked link hands the recipient the sender's subscription, so every private host, path marker and
/// credential parameter the policy lists gets its own row, on an ordinary host where no other rule can
/// reject it first. (A parameter row on patreon.com would stay refused by the host rule even if the
/// parameter rule were deleted.) The first four tests are PrivateFeedLinkTests' link-policy tables,
/// copied from the Mac-only target so this lane runs them too.
final class ShareableLinkPolicyTests: XCTestCase {
    // MARK: Copied from PrivateFeedLinkTests

    func testLinkPolicyKeepsCommonPublicPodcastHostsShareable() {
        let publicLinks = [
            "https://traffic.megaphone.fm/ABC1234567890.mp3?updated=1790000000",
            "https://cdn.simplecast.com/audio/8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f/episodes/1b2c3d4e-5f60-4718-293a-4b5c6d7e8f90/audio/128/default.mp3",
            "https://traffic.omny.fm/d/clips/8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f/1b2c3d4e-5f60-4718-293a-4b5c6d7e8f90/audio.mp3?utm_source=Podcast&in_playlist=2c3d4e5f-6071-4829-3a4b-5c6d7e8f9001",
            "https://sphinx.acast.com/p/open/s/5f1e2d3c4b5a697887766554/e/64a1b2c3d4e5f60718293a4b/media.mp3",
            "https://www.buzzsprout.com/123456/12345678-episode-title.mp3",
            "https://rss.art19.com/episodes/8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f.mp3",
            "https://dts.podtrac.com/redirect.mp3/chrt.fm/track/ABC123/traffic.megaphone.fm/XYZ9876543210.mp3",
            "https://anchor.fm/s/abc123/podcast/play/12345678/https%3A%2F%2Fd3ctxlq1ktw2nl.cloudfront.net%2Fstaging%2F2026-9-1%2F12345678-44100-2-abcdef1234567890.m4a"
        ]
        for link in publicLinks {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(link), link, link)
        }
        XCTAssertEqual(ShareableLinkPolicy.shareableLink("http://example.com/essay"), "http://example.com/essay")
    }

    /// #209: Amperwave (Audacy) feeds from Apple's top charts end in 32 hex digits without
    /// hyphens, which `UUID(uuidString:)` rejects, so they were stripped from packets as private.
    /// The exemption is scoped to that public feed host; the same shape elsewhere stays private.
    func testPublicAmperwaveFeedKeepsItsLinkButTheSameShapeElsewhereStaysPrivate() {
        let publicFeeds = [
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f",
            "https://rss.amperwave.net/v2/feed/audacynetwork/e69da14a26973f1dc761432876205254"
        ]
        for feed in publicFeeds {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(feed), feed, feed)
        }
        let stillPrivate = [
            // A private token of the same shape on any other host.
            "https://feeds.example.net/v2/feed/network/16aa3c6bf526fae9db63070c73cad09f",
            // Longer than a hyphenless UUID, or not hex: still a secret on Amperwave too.
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f16aa3c6b",
            "https://rss.amperwave.net/v2/feed/audacynetwork/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZn",
            // Private markers and credential parameters are never exempt.
            "https://rss.amperwave.net/v2/feed/private/16aa3c6bf526fae9db63070c73cad09f",
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f?token=abc"
        ]
        for link in stillPrivate {
            XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
        }
    }

    func testLinkPolicyRejectsLinksThatCanGrantAccess() {
        let privateLinks = [
            "https://www.patreon.com/rss/someshow?auth=abc",
            "https://feeds.supercast.com/episodes/abc",
            "https://api.substack.com/feed/podcast/424242/private/abc.rss",
            "https://user:pass@example.com/feed.rss",
            "https://example.com/feed.rss?token=short",
            "https://example.com/feed.rss?X-Amz-Signature=abc&X-Amz-Expires=300",
            "https://example.com/audio.mp3?Policy=abc&Key-Pair-Id=def",
            "https://example.com/premium/feed.rss",
            "https://cdn.example.net/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode.mp3",
            "https://example.com/feed.rss?s=Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq==",
            "file:///var/mobile/Containers/Data/Application/ABC/Library/episode.mp3",
            "not a link"
        ]
        for link in privateLinks {
            XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
        }
    }

    func testEpisodeGUIDIsKeptUnlessItIsAPrivateLink() {
        XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID("patreon-98765"), "patreon-98765")
        XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID("8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f"), "8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f")
        XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID("https://example.com/?p=123"), "https://example.com/?p=123")
        XCTAssertNil(ShareableLinkPolicy.shareableEpisodeGUID("https://www.patreon.com/posts/98765?token=abc"))
        XCTAssertNil(ShareableLinkPolicy.shareableEpisodeGUID("http://user:secret@example.com/episode"))
    }

    // MARK: One row per private host

    /// Every host the policy names is refused as itself and as any subdomain. Matching is on whole domain
    /// labels, so a different site that merely contains the name is an ordinary link.
    func testEveryPrivateFeedHostIsRefusedWithItsSubdomains() {
        let privateHosts = [
            "patreon.com", "patreonusercontent.com",
            "supercast.com", "supercast.tech",
            "supportingcast.fm",
            "memberful.com", "memberfulcontent.com"
        ]
        for host in privateHosts {
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://\(host)/feed.rss"), host)
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://feeds.\(host)/abc/feed.rss"), "subdomain of \(host)")
            XCTAssertNotNil(ShareableLinkPolicy.shareableLink("https://not\(host)/feed.rss"), "not\(host) is another site")
            XCTAssertNotNil(ShareableLinkPolicy.shareableLink("https://\(host).example.org/feed.rss"), "\(host).example.org is another site")
        }
    }

    /// A link is returned exactly as written, so the policy has to read the host and the scheme without
    /// regard to case. A paid-feed link pasted in capitals is still that site's link.
    func testHostAndSchemeAreReadWithoutRegardToCase() {
        XCTAssertNil(ShareableLinkPolicy.shareableLink("HTTPS://WWW.PATREON.COM/rss/x"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://Feeds.SuperCast.Com/episodes/abc"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://Abc.Memberful.COM/feed.rss"))
        let publicLink = "HTTPS://Cdn.Example.COM/Episode-One.mp3"
        XCTAssertEqual(ShareableLinkPolicy.shareableLink(publicLink), publicLink)
    }

    // MARK: One row per path marker

    /// Each marker is refused as a whole path segment, with or without an extension, on any host, in any case.
    func testEveryPrivatePathMarkerIsRefusedOnAnOrdinaryHost() {
        let markers = [
            "private", "premium", "paid",
            "subscriber", "subscribers", "member", "members",
            "patron", "patrons", "supporter", "supporters"
        ]
        for marker in markers {
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/\(marker)/feed.rss"), marker)
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/shows/\(marker).rss"), "\(marker).rss")
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/\(marker.uppercased())/feed.rss"), marker.uppercased())
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/\(marker.capitalized)/feed.rss"), marker.capitalized)
        }
    }

    // MARK: One row per credential parameter

    /// Each name fragment the policy treats as a credential, on its own, with a value too short to look like
    /// a secret, so only the parameter name can reject the link. Names match as substrings and in any case.
    func testEveryCredentialParameterNameIsRefusedOnAnOrdinaryHost() {
        let fragments = [
            "token", "auth", "key", "secret", "sig", "hash", "pass", "pwd",
            "session", "credential", "jwt", "expire", "policy", "hmac", "access"
        ]
        for fragment in fragments {
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/feed.rss?\(fragment)=1"), fragment)
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/feed.rss?\(fragment.uppercased())=1"), fragment.uppercased())
            XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/feed.rss?x=1&my_\(fragment)_value=1"), "my_\(fragment)_value")
        }
        for link in [
            "https://example.com/feed.rss?utm_source=newsletter&updated=1790000000",
            "https://example.com/feed.rss?episode=12&format=mp3"
        ] {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(link), link, "ordinary tracking parameters are not credentials")
        }
    }
}
