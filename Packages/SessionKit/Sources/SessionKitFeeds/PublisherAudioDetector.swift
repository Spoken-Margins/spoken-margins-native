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

/// Length alone cannot distinguish narration from a podcast transcript. Require an affirmative
/// publisher declaration before changing audio import into article import.
public enum PublisherAudioDetector {
    /// A minimum article body, applied only after affirmative narration evidence.
    public static let minimumBodyWords = 600
    public static let detectedFromFeedEnclosure = "feed_enclosure"
    public static let detectedFromPublisherNarration = "substack_post_voiceover"
    /// Substack's automatic narration of a post whose author recorded nothing (#810).
    public static let detectedFromGeneratedNarration = "substack_post_generated_voice"

    public static func kind(audioURL: String?, pageURL: String, bodyWordCount: Int?, publisherNarrationConfirmed: Bool = false) -> FeedEntryMediaKind {
        guard let audio = httpsURL(audioURL) else { return .article }
        guard publisherNarrationConfirmed, let words = bodyWordCount, words >= minimumBodyWords,
              let page = httpsURL(pageURL), page != audio else { return .podcastEpisode }
        return .articleWithPublisherAudio
    }

    public static func kind(of item: ParsedFeedItem) -> FeedEntryMediaKind {
        kind(audioURL: item.audioURL, pageURL: item.url, bodyWordCount: bodyWordCount(of: item))
    }

    public static func kind(of entry: FeedEntry) -> FeedEntryMediaKind {
        kind(audioURL: entry.audioURL, pageURL: entry.canonicalURL, bodyWordCount: entry.bodyWordCount, publisherNarrationConfirmed: entry.publisherNarrationConfirmed == true)
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
        return PublisherAudio(itemId: itemId, audioURL: audioURL, durationMs: entry.audioDurationMs,
                              detectedFrom: entry.publisherNarrationGenerated == true ? detectedFromGeneratedNarration : detectedFromPublisherNarration)
    }

    /// An authenticated feed already supplied this text. Do not replace it with a public teaser.
    public static func articleHandoff(for entry: FeedEntry) -> BrowserTextHandoff? {
        guard entry.hasPublisherAudio else { return nil }
        return feedBodyHandoff(for: entry)
    }

    /// The text the feed itself carried, for an import that must not read the post page (#2368): a followed
    /// Substack post added by "Add every new item", which the listener didn't start. Nil when the feed gave none.
    public static func feedBodyHandoff(for entry: FeedEntry) -> BrowserTextHandoff? {
        guard let body = entry.fullBody, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return BrowserTextHandoff(captureMode: .readablePage,
            source: BrowserTextSource(url: entry.canonicalURL, title: entry.title), text: body)
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
