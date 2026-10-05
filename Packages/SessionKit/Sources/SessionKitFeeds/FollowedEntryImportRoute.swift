import Foundation
import SessionKit

/// How Following adds one entry to the Library. A podcast feed can also carry text-only posts
/// (a publication with some voiceovers): those have nothing to play, so they import as articles
/// like entries of an article feed (#641). They used to take the podcast path with the post's
/// page as the audio, which failed with "did not expose playable audio".
public enum FollowedEntryImportRoute: Equatable, Sendable {
    /// Import this address through the podcast path: the entry's audio, or its page when no
    /// audio is known.
    case episode(audioURL: String)
    /// Import the entry's text, keeping any publisher recording beside it (#545).
    case article

    public static func route(for entry: FeedEntry, subscriptionKind: SourceIdentityKind, audio: FollowedEntryAudio) -> Self {
        guard needsAudioLookup(for: entry, subscriptionKind: subscriptionKind) else { return .article }
        switch audio {
        case .found(let audioURL) where !audioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return .episode(audioURL: audioURL)
        case .noneInFeed:
            return .article
        case .found, .unknown:
            // As before #641: the podcast path tries the entry's page, for an episode that left
            // the feed or no longer matches it.
            return .episode(audioURL: entry.canonicalURL)
        }
    }

    /// Whether the entry could be an episode, so its audio is worth looking up: it comes from a
    /// podcast feed and isn't a post with the publisher's own recording.
    public static func needsAudioLookup(for entry: FeedEntry, subscriptionKind: SourceIdentityKind) -> Bool {
        subscriptionKind == .podcastFeed && !entry.hasPublisherAudio
    }
}

/// What is known about a followed entry's audio when it is added (#641).
public enum FollowedEntryAudio: Equatable, Sendable {
    /// The stored enclosure, or one recovered from the feed for an older entry saved without it.
    case found(String)
    /// The feed still lists the entry and gives it no audio enclosure: a text-only post.
    case noneInFeed
    /// Nothing known: the feed no longer lists the entry, or there was no feed to ask.
    case unknown

    /// Only what the entry itself stores, without asking the feed.
    public static func stored(in entry: FeedEntry) -> Self {
        entry.audioURL.map(Self.found) ?? .unknown
    }
}
