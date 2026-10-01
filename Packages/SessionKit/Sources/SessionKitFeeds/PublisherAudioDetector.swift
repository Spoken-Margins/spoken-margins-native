import Foundation
import SessionKit

/// What a followed feed's entry is when it's added to the Library (#545, slice 1 of #239).
public enum FeedEntryMediaKind: String, Equatable, Sendable {
    /// An episode: it imports as audio from its enclosure, as podcast entries always have.
    case podcastEpisode = "podcast_episode"
    /// A full post that also carries the publisher's own recording, such as a Substack voiceover:
    /// it imports as an article with its text, and the recording is remembered beside it.
    case articleWithPublisherAudio = "article_with_publisher_audio"
    /// A post with no audio.
    case article
}

/// Tells a post that carries the publisher's audio from a podcast episode. Feeds with any audio
/// enclosure are followed as podcast feeds, so before this a publication that added voiceovers
/// lost its text. Show notes are short, and a post's full body comes in its own element, so an
/// entry with an audio enclosure is an article only when that body is long and its link is a
/// page of its own rather than the audio file.
public enum PublisherAudioDetector {
    /// Show notes rarely reach this; a post that carries a voiceover nearly always does.
    public static let minimumBodyWords = 600
    public static let detectedFromFeedEnclosure = "feed_enclosure"

    public static func kind(audioURL: String?, pageURL: String, bodyWordCount: Int?) -> FeedEntryMediaKind {
        guard let audio = httpsURL(audioURL) else { return .article }
        guard let words = bodyWordCount, words >= minimumBodyWords,
              let page = httpsURL(pageURL), page != audio else { return .podcastEpisode }
        return .articleWithPublisherAudio
    }

    public static func kind(of item: ParsedFeedItem) -> FeedEntryMediaKind {
        kind(audioURL: item.audioURL, pageURL: item.url, bodyWordCount: bodyWordCount(of: item))
    }

    public static func kind(of entry: FeedEntry) -> FeedEntryMediaKind {
        kind(audioURL: entry.audioURL, pageURL: entry.canonicalURL, bodyWordCount: entry.bodyWordCount)
    }

    /// Words in the item's full body, or nil when the feed gives no body apart from its description.
    public static func bodyWordCount(of item: ParsedFeedItem) -> Int? {
        item.content.map(wordCount)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }

    /// The record to keep beside the article imported from `entry`, or nil when the entry isn't
    /// an article with publisher audio.
    public static func publisherAudio(for entry: FeedEntry, itemId: String) -> PublisherAudio? {
        guard kind(of: entry) == .articleWithPublisherAudio, let audioURL = httpsURL(entry.audioURL) else { return nil }
        return PublisherAudio(itemId: itemId, audioURL: audioURL, durationMs: entry.audioDurationMs, detectedFrom: detectedFromFeedEnclosure)
    }

    private static func httpsURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https", !(components.host ?? "").isEmpty else { return nil }
        return raw
    }
}

public extension FeedEntry {
    /// True when this entry is a full post with the publisher's own audio (#545).
    var hasPublisherAudio: Bool { PublisherAudioDetector.kind(of: self) == .articleWithPublisherAudio }
}
