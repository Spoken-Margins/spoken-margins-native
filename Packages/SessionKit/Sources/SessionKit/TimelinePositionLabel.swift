import Foundation

/// What a Timeline card says about where it is, in the item's own unit (#3862): the clock on media, a percentage on text,
/// so the card and the playback screen's scrubber can't disagree. A podcast's publisher chapters are saved with their exact
/// start times, so a chapter that has one shows it ("1:07:30"); a chapter or Margin placed only by a fraction shows
/// "65%", and on a timed item a chapter says "about 65%" so a rough place is never read as an exact time. No time is ever
/// made from a percentage. All numbers go through `PlaybackPositionText`, so the Timeline, the scrubber and VoiceOver's Skim
/// destinations share one formatter.
public enum TimelinePositionLabel {
    public enum ItemKind: Equatable, Sendable {
        /// A podcast or other audio file: its scrubber shows the clock.
        case media
        /// An article, PDF or note read aloud: its scrubber shows a percentage.
        case text
    }

    public struct Label: Equatable, Sendable {
        /// The card's corner: "1:07:30" or "65%".
        public var corner: String
        /// What VoiceOver reads for the corner: "1 hour, 7 minutes, 30 seconds" or "65 percent".
        public var spoken: String

        public init(corner: String, spoken: String) {
            self.corner = corner
            self.spoken = spoken
        }
    }

    /// The label for one card.
    /// - Parameters:
    ///   - startMs: the card's exact start in the media, when it has one (a publisher or media chapter, a scene, a Margin
    ///     taken at a time). Text items never show a time, so it is ignored for `.text`.
    ///   - percent: where the card is as a share of the item, from the saved fraction.
    public static func label(kind: ItemKind, startMs: Int?, percent: Int) -> Label {
        // A negative start is not a real chapter time: it falls back to the fraction rather than showing an exact 0:00.
        if kind == .media, let startMs, startMs >= 0 {
            let time = PlaybackPositionText.visible(ms: startMs)
            return Label(corner: time, spoken: PlaybackPositionText.spoken(ms: startMs))
        }
        return Label(corner: PlaybackPositionText.visible(percent: percent), spoken: PlaybackPositionText.spoken(percent: percent))
    }

    /// The label for a chapter card (#4778). A chapter card shows its place once, in the corner, so a chapter on a timed
    /// item with no usable exact start says "about 65%" there ("about 65 percent" to VoiceOver): a rough place never reads
    /// as an exact one (#3862). Everything else is `label(kind:startMs:percent:)`.
    public static func chapterLabel(kind: ItemKind, startMs: Int?, percent: Int) -> Label {
        let label = label(kind: kind, startMs: startMs, percent: percent)
        let hasExactStart = startMs.map { $0 >= 0 } ?? false
        guard kind == .media, !hasExactStart else { return label }
        return Label(corner: "about \(label.corner)", spoken: "about \(label.spoken)")
    }

    /// The whole percent the listener is through a media item, rounded down so 99.6% shows 99% until the item is finished.
    /// Nil when the duration is not known, so no number is made up.
    public static func mediaPercent(currentMs: Int, durationMs: Int?) -> Int? {
        durationMs.flatMap { PlaybackPositionText.percent(position: currentMs, length: $0) }
    }

    /// The percent a text item's scrubber prints for a character offset: nearest whole percent, 0...100, and 0 while the length is
    /// unknown. The playback screen's scrubber and the Timeline's current line both call this, so they can't disagree (#3862).
    public static func textScrubberPercent(offset: Double, length: Int) -> Int {
        guard length > 0 else { return 0 }
        return max(0, min(100, Int((offset / Double(length) * 100).rounded())))
    }

    /// The media scrubber's VoiceOver value with the listener's percent added: "1:06:48 of 1:43:00, 64 percent". The value is
    /// returned unchanged while the duration is unknown, so no number is made up.
    public static func appendingSpokenPercent(to value: String, currentMs: Int, durationMs: Int?) -> String {
        guard let percent = mediaPercent(currentMs: currentMs, durationMs: durationMs) else { return value }
        return "\(value), \(PlaybackPositionText.spoken(percent: percent))"
    }

    /// The current card's line: the current label with the listener's position, on whatever kind of card is current.
    /// Media: "Current chapter · 1:06:48 · 64%", and "Current chapter · 1:06:48" while the duration is unknown. Text:
    /// "Current chapter · 47%". With nothing to add it is the label alone.
    public static func currentLine(currentLabel: String, currentMs: Int?, percent: Int?, isMedia: Bool) -> String {
        var parts = [currentLabel]
        if isMedia, let currentMs { parts.append(PlaybackPositionText.visible(ms: currentMs)) }
        if let percent { parts.append(PlaybackPositionText.visible(percent: percent)) }
        return parts.joined(separator: " · ")
    }
}
