import XCTest
@testable import SessionKit

/// #1050: a secret kept in the `#fragment`, or hidden behind percent-encoding in the path, must be
/// refused like the same secret in the query or the plain path. The fragment never reaches a server,
/// but the link is copied into packets, notes, OPML, Readwise and the community map, and the
/// promise for a private link is that it never leaves the phone.
///
/// Rule chosen for fragments: only credential-looking fragments are refused, because an ordinary
/// anchor (`#section-2`) is on every public article. A fragment is read three ways:
/// - as a query string when it holds `=` or `?` (`#token=abc`, `#/episodes?token=abc`): the query rules;
/// - as a route when it holds `/` (`#/private/abc`, `#!/members/abc`): the path rules;
/// - otherwise as a bare anchor: refused only when the whole anchor is a long opaque token.
///
/// The path is percent-decoded before the marker and secret checks, until it stops changing, because
/// some servers and proxies decode twice.
final class ShareableLinkPolicyFragmentTests: XCTestCase {
    private let secret = "Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq"

    func testFragmentsAndEncodedPathsThatCarryACredentialAreRefused() {
        let refused = [
            // The cases from the issue.
            "https://example.com/feed.rss#token=abcdef",
            "https://example.com/feed.rss#auth=abc",
            "https://example.com/feed.rss#/private/abc123",
            "https://example.com/feed.rss#\(secret)",
            "https://example.com/feed.rss?x=1#key=abc",
            "https://example.com/%70remium/feed.rss",
            "https://example.com/Pre%6dium/feed.rss",

            // Case.
            "https://example.com/feed.rss#TOKEN=abc",
            "https://example.com/feed.rss#Access_Token=abc&Token_Type=bearer",
            "https://example.com/feed.rss#/PRIVATE/abc123",
            "https://example.com/%50REMIUM/feed.rss",
            "https://example.com/%70REMIUM/feed.rss",

            // Whitespace and punctuation around the name, written percent-encoded.
            "https://example.com/feed.rss#%20token=abc",
            "https://example.com/feed.rss#token=%20abc",
            "https://example.com/feed.rss#token%3Dabc",

            // Double encoding.
            "https://example.com/%2570remium/feed.rss",
            "https://example.com/%252570remium/feed.rss",
            "https://example.com/feed.rss#%2574oken=abc",
            "https://example.com/feed.rss#token%253Dabc",

            // Mixed query and fragment: either part is enough.
            "https://example.com/feed.rss?x=1#/members/abc",
            "https://example.com/feed.rss?token=abc#section-2",
            "https://example.com/feed.rss?utm_source=news#token=abc",

            // Fragment shapes: OAuth-style, a route with a query, a hashbang route, a secret value.
            "https://example.com/feed.rss#access_token=abc&token_type=bearer",
            "https://example.com/app#/episodes?token=abc",
            "https://example.com/app#!/members/abc",
            "https://example.com/app#/episodes/\(secret)",
            "https://example.com/feed.rss#id=\(secret)",
            "https://example.com/feed.rss#\(secret).m4a",

            // A secret or a marker that a single encoded character hides from the plain check.
            "https://example.com/Zk9x%512hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode.mp3",
            "https://example.com/shows%2Fpremium%2Ffeed.rss",
            "https://example.com/shows%2fMembers.rss",

            // The public hex-identifier host keeps its exemption for the path only.
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f#token=abc",
            "https://rss.amperwave.net/v2/feed/%70rivate/16aa3c6bf526fae9db63070c73cad09f",

            // Already refused today; pinned so the new fragment code cannot loosen them.
            "#token=abc",
            "https://#token=abc",
            "token=abc"
        ]
        for link in refused {
            XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
            if link.hasPrefix("http") {
                XCTAssertNil(ShareableLinkPolicy.shareableEpisodeGUID(link), "as a GUID: \(link)")
            }
        }
    }

    func testOrdinaryAnchorsAndEncodedCharactersStayShareable() {
        let shareable = [
            // A public article with an anchor.
            "https://example.com/essay#section-2",
            "https://example.com/essay#footnote-1",
            "https://example.com/essay?page=2#comments",
            "https://example.com/essay.html#t=125",
            "https://example.com/watch?v=abc#t=1m30s",

            // Anchors that contain a credential word inside an ordinary word are not credentials,
            // and neither is a bare marker word: a heading anchor is not a secret.
            "https://example.com/essay#design",
            "https://example.com/essay#passing-grade",
            "https://example.com/essay#members",
            "https://example.com/essay#token",
            "https://example.com/essay#Private-Data",

            // Empty fragments, with and without a query.
            "https://example.com/feed.rss#",
            "https://example.com/feed.rss?x=1#",

            // Routes and queries inside a fragment that carry no credential.
            "https://example.com/app#/episodes/12",
            "https://example.com/app#!/episodes/12",
            "https://example.com/app#/episodes?page=2&format=mp3",
            "https://example.com/app#page=2",

            // A text-fragment directive quotes the page; the quoted words are not a secret.
            "https://example.com/essay#:~:text=Spoken%20Margins",
            "https://example.com/essay#:~:text=the%20key%20idea",

            // Percent-encoding that decodes to ordinary text.
            "https://example.com/caf%C3%A9/feed.rss",
            "https://example.com/100%25-sure/feed.rss",
            "https://example.com/my%20show/feed.rss",
            "https://example.com/shows%2Fnews%2Ffeed.rss",

            // An encoded URL inside one path segment (anchor.fm) is one segment, not 33 secret characters.
            "https://anchor.fm/s/abc123/podcast/play/12345678/https%3A%2F%2Fd3ctxlq1ktw2nl.cloudfront.net%2Fstaging%2F2026-9-1%2F12345678-44100-2-abcdef1234567890.m4a",

            // The public hex-identifier host keeps its exemption, with an ordinary anchor.
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f#section-2"
        ]
        for link in shareable {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(link), link, link)
        }
    }

    /// The secret-shape rule is the one the path and query already use, so a long opaque anchor is
    /// refused and so is a long heading slug that holds a digit, just as a long path slug is today.
    /// That costs a recipient an automatic match on such a link, which the policy accepts over
    /// handing out a token. If the shape rule is ever narrowed, this row changes with it.
    func testLongHeadingSlugWithADigitIsRefusedLikeALongPathSlug() {
        let slug = "installing-version-2-on-linux-and-macos"
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/docs/\(slug)"))
        XCTAssertNil(ShareableLinkPolicy.shareableLink("https://example.com/docs#\(slug)"))
        XCTAssertNotNil(ShareableLinkPolicy.shareableLink("https://example.com/docs#installing-on-linux"))
    }
}
