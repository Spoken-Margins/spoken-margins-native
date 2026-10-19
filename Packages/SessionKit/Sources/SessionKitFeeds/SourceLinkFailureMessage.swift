import Foundation
import SessionKit

/// What the listener is told when a pasted or shared link can't be played. The reason codes come from
/// `PublicPodcastLinkResolver`; a reason it doesn't know passes through as written.
public enum SourceLinkFailureMessage {
    public static func text(status: String?, reason: String?, provider: String?) -> String {
        switch reason {
        case "spotify_audio_requires_provider_playback":
            if provider == "spotify" {
                return "Spoken Margins could not find a public audio file for this Spotify episode."
            }
            return "This provider did not expose a public audio file that Spoken Margins can play yet."
        case "spotify_metadata_unavailable":
            return "Spotify did not return enough episode metadata to search for a public copy."
        case "spotify_specific_episode_required":
            return "Open the specific episode in Spotify, tap Share, and send its episode link. Show or podcast-page links do not identify one episode."
        case "spotify_episode_not_found_on_apple":
            return "I could not find a confident Apple Podcasts match for this Spotify episode. It may be Spotify-only."
        case "spotify_episode_match_ambiguous":
            return "I found more than one Apple Podcasts episode with this title, so I did not risk importing the wrong one. Try sharing the specific Apple Podcasts episode or its RSS link."
        case "apple_episode_id_missing":
            return "That Apple Podcasts link did not identify a specific episode."
        case "apple_lookup_empty":
            return "Apple Podcasts did not return this episode from lookup, and I could not find a public audio stream on the Apple page."
        case "apple_audio_enclosure_not_found":
            return "Apple Podcasts did not expose a playable public audio stream for that episode."
        case "audio_enclosure_not_found":
            return "I found the page or feed, but not a playable podcast/audio file."
        case "pdf_document":
            return "That link is a PDF document, not a podcast or audio file."
        case "rss_episode_ambiguous":
            return "I found the feed, but could not identify one episode to play."
        case "unsupported_link_type":
            return "That link is not a supported public podcast, RSS feed, or direct audio file."
        case "apple_lookup_failed":
            return "Apple Podcasts did not return a playable public audio file for that episode."
        case "no_link_resolver_configured":
            return "That link is not playable in Spoken Margins yet."
        case "invalid_url":
            return "That doesn't look like a web link I can use. Check the address."
        case "rss_feed_empty":
            return "That feed has no episodes in it yet."
        case "rss_audio_enclosure_missing":
            return "I found that episode, but it has no audio file to play."
        case .some(let message):
            return message
        case .none:
            if status == LinkResolutionStatus.unsupported.rawValue {
                return "That link is not playable in Spoken Margins yet."
            }
            return "Source link needs review before it can be played."
        }
    }
}
