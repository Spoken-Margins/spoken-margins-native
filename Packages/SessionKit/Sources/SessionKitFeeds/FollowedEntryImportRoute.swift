import Foundation
import SessionKit

/// How Following adds one entry to the Library. A podcast feed can also carry text-only posts
/// (a publication with some voiceovers): those have nothing to play, so they import as articles
/// like entries of an article feed (#641). They used to take the podcast path, which failed with
/// "did not expose playable audio" and left the post unadded.
public enum FollowedEntryImportRoute: Equatable, Sendable {
    /// Import the audio at this address as an episode.
    case episode(audioURL: String)
    /// Import the entry's text, keeping any publisher recording beside it (#545).
    case article

    /// `playableAudioURL` is the entry's enclosure, or one recovered from the feed for an older
    /// entry saved without it. Ask for it only when `needsPlayableAudioURL` says so: recovering
    /// it can refetch the feed.
    public static func route(for entry: FeedEntry, subscriptionKind: SourceIdentityKind, playableAudioURL: String?) -> Self {
        guard needsPlayableAudioURL(for: entry, subscriptionKind: subscriptionKind),
              let audioURL = playableAudioURL?.trimmingCharacters(in: .whitespacesAndNewlines), !audioURL.isEmpty else {
            return .article
        }
        return .episode(audioURL: audioURL)
    }

    /// Whether the entry could be an episode: it comes from a podcast feed and isn't a post with
    /// the publisher's own recording.
    public static func needsPlayableAudioURL(for entry: FeedEntry, subscriptionKind: SourceIdentityKind) -> Bool {
        subscriptionKind == .podcastFeed && !entry.hasPublisherAudio
    }
}
