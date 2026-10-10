import XCTest
@testable import SessionKit

/// #945: an equivalent private link written with percent-encoding must be withheld exactly like its
/// plain spelling. #1050 made the policy decode each path segment before the marker and token checks;
/// this table pins the cases that fix did not name: the encoded token, mixed-case escapes, encoded
/// separators and dots, malformed escapes, and the ordinary public paths that must stay shareable.
///
/// The policy only classifies. The link it returns is the caller's own string, byte for byte, so an
/// accepted link is never decoded or normalised on its way into a packet or an OPML file.
final class ShareableLinkPolicyEncodingTests: XCTestCase {
    private let host = "https://feeds.example.net"
    private let token = "Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq"

    /// Every row is a private link on an ordinary host whose plain spelling is refused. Each plain
    /// spelling is checked too, so a row cannot pass because the plain form was never private.
    func testEncodedSpellingsOfPrivateLinksAreRefusedLikeTheirPlainSpelling() {
        let pairs: [(plain: String, encoded: [String])] = [
            // The three rows from the issue.
            ("/private/abc.rss", ["/%70rivate/abc.rss"]),
            ("/premium/feed.rss", ["/%70remium/feed.rss"]),
            ("/\(token)/episode.mp3", ["/%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode.mp3"]),

            // Hex digits in either case decode to the same character.
            ("/premium/feed.rss", ["/Pre%6Dium/feed.rss", "/Pre%6dium/feed.rss", "/%50%52EMIUM/feed.rss", "/%70%72%65%6d%69%75%6d/feed.rss"]),
            ("/members/feed.rss", ["/me%6Dbers/feed.rss", "/me%6dbers/feed.rss"]),
            ("/\(token)/episode.mp3", ["/%5a\(token.dropFirst())/episode.mp3", "/%5A\(token.dropFirst())/episode.mp3"]),

            // A token with one or several characters encoded, including the two non-alphanumerics it may hold.
            ("/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNk-ZWZnaGlq/e.mp3", ["/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNk%2DZWZnaGlq/e.mp3", "/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNk%2dZWZnaGlq/e.mp3"]),
            ("/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNk_ZWZnaGlq/e.mp3", ["/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNk%5FZWZnaGlq/e.mp3", "/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNk%5fZWZnaGlq/e.mp3"]),
            ("/\(token)/episode.mp3", ["/%5A%6b%39%78Q2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode.mp3", "/\(token.dropLast())%71/episode.mp3"]),
            ("/\(token).mp3", ["/%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq.mp3", "/\(token)%2Emp3"]),

            // A marker behind an encoded separator, an encoded dot, or in a later segment.
            ("/shows/premium/feed.rss", ["/shows%2Fpremium%2Ffeed.rss", "/shows%2fpremium%2ffeed.rss", "/shows/%70remium/feed.rss"]),
            ("/shows/premium.rss", ["/shows/premium%2Erss", "/shows/%70remium%2erss"]),
            ("/shows/\(token)/e.mp3", ["/shows%2F\(token)/e.mp3", "/shows%2f%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/e.mp3"]),

            // A token with an encoded slash before it, after it, or repeated, at either end of a segment.
            ("/\(token)/e.mp3", [
                "/\(token)%2F/e.mp3", "/\(token)%2f/e.mp3", "/%2F\(token)/e.mp3", "/%2F\(token)%2F/e.mp3",
                "/\(token)%2F%2F/e.mp3", "/%2F%2F\(token)/e.mp3", "/\(token)%252F/e.mp3", "/%252F\(token)/e.mp3",
                "/%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq%2F/e.mp3", "/\(token)%2F.mp3",
            ]),
            ("/\(token)", ["/\(token)%2F", "/%2F\(token)"]),
            ("/premium/feed.rss", ["/%2F%70remium/feed.rss", "/%70remium%2F/feed.rss", "/%252F%2570remium/feed.rss"]),

            // Encoded more than once, as a server or proxy that decodes twice would read it.
            ("/premium/feed.rss", ["/%2570remium/feed.rss", "/%252570remium/feed.rss", "/%2550remium/feed.rss"]),
            ("/\(token)/e.mp3", ["/%255Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/e.mp3"]),

            // The same secret in the query: the name and the value are read decoded.
            ("/feed.rss?token=abc", ["/feed.rss?%74oken=abc", "/feed.rss?%54OKEN=abc"]),
            ("/feed.rss?s=\(token)", ["/feed.rss?s=%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq", "/feed.rss?s=%5ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq"]),
        ]
        for pair in pairs {
            let plain = host + pair.plain
            XCTAssertNil(ShareableLinkPolicy.shareableLink(plain), "plain spelling: \(plain)")
            for path in pair.encoded {
                let link = host + path
                XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
                XCTAssertNil(ShareableLinkPolicy.shareableEpisodeGUID(link), "as a GUID: \(link)")
            }
        }
    }

    /// A malformed escape (`%zz`, a lone `%`, `%4`) is not decoded the way a valid one is. A server
    /// that is lenient reads the valid escapes and leaves the bad one as text, so a marker or token
    /// in the same segment is still there. The policy must not stop decoding because one escape is bad.
    func testMalformedEscapesDoNotHideAMarkerOrATokenInTheSameLink() {
        let refused = [
            // The bad escape sits in another segment, or in the query: the marker is plain or encoded.
            "/%zz/premium/feed.rss",
            "/%zz/%70remium/feed.rss",
            "/premium/%zz/feed.rss",
            "/%/%70remium/feed.rss",
            "/%70remium/feed.rss?x=%zz",
            "/%70remium/feed.rss?x=%",
            // The bad escape trails a marker that a valid escape spells, after its extension.
            "/%70remium.rss%zz",
            "/%70remium.rss%",
            "/%70remium.rss%4",
            // The same in the query, where the value is a token or the name is a credential word.
            "/feed.rss?s=\(token)%zz",
            "/feed.rss?s=%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq%zz",
            "/feed.rss?%74oken=abc%zz",
            "/feed.rss?%74oken=%",
            // A token whose own encoded character is next to a bad escape.
            "/%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq%zz/e.mp3",
            "/%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq%/e.mp3",
            "/%zz%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/e.mp3",
            // A plain token with a stray escape in the same segment.
            "/\(token)%zz/e.mp3",
            "/\(token)%/e.mp3",
            "/%zz\(token)/e.mp3",
            "/\(token.prefix(20))%zz\(token.dropFirst(20))/e.mp3",
        ]
        for path in refused {
            let link = host + path
            XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
        }
    }

    /// Public paths that hold encoded characters stay shareable, and come back byte for byte: nothing
    /// is decoded, re-encoded or trimmed on the way out. Each row is a neighbour of a refused row:
    /// the same escapes, none of them spelling a marker or making a long opaque token.
    func testOrdinaryEncodedPublicPathsStayShareableAndUnchanged() {
        let shareable = [
            // Escapes that decode to ordinary text.
            "/caf%C3%A9/feed.rss",
            "/caf%c3%a9/feed.rss",
            "/my%20show/feed.rss",
            "/100%25-sure/feed.rss",
            "/shows%2Fnews%2Ffeed.rss",
            "/shows%2fnews%2ffeed.rss",
            "/a%2Bb/feed.rss",
            "/episode-%31%32.mp3",

            // A word that merely contains a marker, or reads like one with a character changed.
            "/%70rivacy/policy",
            "/%70remiumization/feed.rss",
            "/%6Dembership/feed.rss",
            "/me%6Dber-stories/feed.rss",
            "/%70rivately/feed.rss",
            "/%70aid-search/feed.rss",
            "/shows/%70remium-picks.rss",

            // A marker is a whole segment (or the stem of one) only; a space makes it another word.
            "/%20private-notes/feed.rss",

            // Long, but not a token: under 32 characters, or letters only, or digits only.
            "/%5Ak9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmN/e.mp3",
            "/%5Ak%39xQ%32hTbtlbjEyMzQ1Njc4OTBhYmN/e.mp3",
            "/%41bcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz/e.mp3",
            "/%31234567890123456789012345678901234567890/e.mp3",

            // UUIDs and the hex ids of public hosts, with their hyphens encoded or not.
            "/episodes/8f2c1c9e%2D1a2b%2D4c3d%2D9e8f%2D0a1b2c3d4e5f.mp3",
            "/episodes/8F2C1C9E-1A2B-4C3D-9E8F-0A1B2C3D4E5F.mp3",
            "/episodes/%38f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f.mp3",

            // An encoded URL inside one segment is one segment, not a long token.
            "/s/abc123/play/12345678/https%3A%2F%2Fd3ctxlq1ktw2nl.cloudfront.net%2Fstaging%2F2026-9-1%2F12345678-44100-2-abcdef1234567890.m4a",

            // An encoded slash at the edge of an ordinary segment.
            "/shows%2F/feed.rss",
            "/%2Fshows/feed.rss",
            "/%2F%2F/feed.rss",
            "/news%2F/%38f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f.mp3",

            // A literal percent sign in the query is ordinary text.
            "/feed.rss?q=100%25&page=2",
            "/feed.rss?title=caf%C3%A9",
        ]
        for path in shareable {
            let link = host + path
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(link), link, link)
            XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID(link), link, "as a GUID: \(link)")
        }
        for link in [
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f",
            "https://rss.amperwave.net/v2/feed/audacynetwork/%31%36aa3c6bf526fae9db63070c73cad09f",
            "https://anchor.fm/s/abc123/podcast/play/12345678/https%3A%2F%2Fd3ctxlq1ktw2nl.cloudfront.net%2Fstaging%2F2026-9-1%2F12345678-44100-2-abcdef1234567890.m4a",
        ] {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(link), link, link)
        }
    }

    /// The hex-identifier exemption belongs to one public host and one exact shape. Writing the same
    /// shape with an escape, or a marker with an escape, does not widen it.
    func testHexIdentifierExemptionDoesNotWidenForEncodedSpellings() {
        let identifier = "16aa3c6bf526fae9db63070c73cad09f"
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://feeds.example.net/v2/feed/network/\(identifier)"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://feeds.example.net/v2/feed/network/%31\(identifier.dropFirst())"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://rss.amperwave.net/v2/feed/%70rivate/\(identifier)"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://rss.amperwave.net/v2/feed/audacynetwork/\(identifier)%31"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://rss.amperwave.net/v2/feed/audacynetwork/\(identifier)?%74oken=abc"))
    }
}
