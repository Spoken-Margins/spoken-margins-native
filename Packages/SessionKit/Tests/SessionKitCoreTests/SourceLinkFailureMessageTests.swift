import XCTest
@testable import SessionKitFeeds
import SessionKit

/// What the listener reads when a link can't be played (#976). Every text is written out here byte for
/// byte; the code is the same table moved out of the app model.
final class SourceLinkFailureMessageTests: XCTestCase {
    func testEveryReasonCodeHasItsExactText() {
        let table: [(reason: String, provider: String?, text: String)] = [
            ("spotify_audio_requires_provider_playback", "spotify", "Spoken Margins could not find a public audio file for this Spotify episode."),
            ("spotify_audio_requires_provider_playback", "apple", "This provider did not expose a public audio file that Spoken Margins can play yet."),
            ("spotify_audio_requires_provider_playback", nil, "This provider did not expose a public audio file that Spoken Margins can play yet."),
            ("spotify_metadata_unavailable", nil, "Spotify did not return enough episode metadata to search for a public copy."),
            ("spotify_specific_episode_required", nil, "Open the specific episode in Spotify, tap Share, and send its episode link. Show or podcast-page links do not identify one episode."),
            ("spotify_episode_not_found_on_apple", nil, "I could not find a confident Apple Podcasts match for this Spotify episode. It may be Spotify-only."),
            ("spotify_episode_match_ambiguous", nil, "I found more than one Apple Podcasts episode with this title, so I did not risk importing the wrong one. Try sharing the specific Apple Podcasts episode or its RSS link."),
            ("apple_episode_id_missing", nil, "That Apple Podcasts link did not identify a specific episode."),
            ("apple_lookup_empty", nil, "Apple Podcasts did not return this episode from lookup, and I could not find a public audio stream on the Apple page."),
            ("apple_audio_enclosure_not_found", nil, "Apple Podcasts did not expose a playable public audio stream for that episode."),
            ("audio_enclosure_not_found", nil, "I found the page or feed, but not a playable podcast/audio file."),
            ("pdf_document", nil, "That link is a PDF document, not a podcast or audio file."),
            ("rss_episode_ambiguous", nil, "I found the feed, but could not identify one episode to play."),
            ("unsupported_link_type", nil, "That link is not a supported public podcast, RSS feed, or direct audio file."),
            ("apple_lookup_failed", nil, "Apple Podcasts did not return a playable public audio file for that episode."),
            ("invalid_url", nil, "That doesn't look like a web link I can use. Check the address."),
            ("rss_feed_empty", nil, "That feed has no episodes in it yet."),
            ("rss_audio_enclosure_missing", nil, "I found that episode, but it has no audio file to play."),
            ("no_link_resolver_configured", nil, "That link is not playable in Spoken Margins yet."),
        ]
        XCTAssertEqual(table.count, 19)
        for row in table {
            XCTAssertEqual(
                SourceLinkFailureMessage.text(status: "needs_review", reason: row.reason, provider: row.provider),
                row.text, row.reason
            )
        }
    }

    func testAReasonWinsOverTheStatus() {
        XCTAssertEqual(
            SourceLinkFailureMessage.text(status: LinkResolutionStatus.unsupported.rawValue, reason: "pdf_document", provider: nil),
            "That link is a PDF document, not a podcast or audio file."
        )
    }

    func testNoReasonAndAnUnsupportedStatusSaysTheLinkIsNotPlayableYet() {
        XCTAssertEqual(
            SourceLinkFailureMessage.text(status: "unsupported", reason: nil, provider: "spotify"),
            "That link is not playable in Spoken Margins yet."
        )
    }

    func testNoReasonAndAnyOtherStatusAsksForReview() {
        for status in [nil, "needs_review", "resolving", "playable", "Unsupported", ""] as [String?] {
            XCTAssertEqual(
                SourceLinkFailureMessage.text(status: status, reason: nil, provider: nil),
                "Source link needs review before it can be played.", "\(String(describing: status))"
            )
        }
    }

    func testAnUnknownReasonPassesThroughUnchanged() {
        for reason in ["Feed is empty.", "Invalid_url", "", " pdf_document", "PDF_DOCUMENT"] {
            XCTAssertEqual(SourceLinkFailureMessage.text(status: "unsupported", reason: reason, provider: "spotify"), reason)
        }
    }
}
