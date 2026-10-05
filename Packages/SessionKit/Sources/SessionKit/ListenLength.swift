import Foundation

/// How long a Following entry takes to hear (D3, #773): an episode's duration, or an article's
/// words at the listener's speech rate. Nil when neither is known, so a row shows nothing rather
/// than "0 min".
public struct ListenLength: Equatable, Sendable {
    /// Words a minute at 1x, the same estimate the Obsidian importer uses for chapter lengths.
    public static let wordsPerMinuteAtNormalRate: Double = 180

    public enum Kind: Equatable, Sendable {
        /// Recorded audio: "42 min".
        case episode
        /// Narrated text: "12 min listen".
        case article
    }

    public var minutes: Int
    public var kind: Kind

    /// - Parameter rate: the listener's speech rate as a multiple of normal (1.5 is 1.5x).
    public init?(audioDurationMs: Int?, bodyWordCount: Int?, rate: Double = 1) {
        if let ms = audioDurationMs, ms > 0 {
            minutes = max(1, Int((Double(ms) / 60_000).rounded()))
            kind = .episode
        } else if let words = bodyWordCount, words > 0 {
            let wordsPerMinute = Self.wordsPerMinuteAtNormalRate * (rate.isFinite && rate > 0 ? rate : 1)
            minutes = max(1, Int((Double(words) / wordsPerMinute).rounded()))
            kind = .article
        } else {
            return nil
        }
    }

    /// An entry with audio is timed only by its duration: its word count is show notes, not the episode.
    public init?(_ entry: FeedEntry, rate: Double = 1) {
        let hasAudio = !(entry.audioURL ?? "").isEmpty
        self.init(audioDurationMs: entry.audioDurationMs, bodyWordCount: hasAudio ? nil : entry.bodyWordCount, rate: rate)
    }

    /// "42 min", "1 h 5 min", or "12 min listen" for an article.
    public var label: String {
        let time = minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        return kind == .article ? "\(time) listen" : time
    }

    /// For VoiceOver: "42 minutes", "1 hour 5 minutes".
    public var spokenLabel: String {
        func unit(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return unit(rest, "minute") }
        return rest == 0 ? unit(hours, "hour") : "\(unit(hours, "hour")) \(unit(rest, "minute"))"
    }
}
