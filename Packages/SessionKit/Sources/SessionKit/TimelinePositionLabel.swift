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
        /// A chapter card's detail line: "Chapter · 1:07:30", "Chapter · about 65%" or, on text, "Chapter · 56%".
        public var chapterDetail: String
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
            return Label(corner: time, spoken: PlaybackPositionText.spoken(ms: startMs), chapterDetail: "Chapter · \(time)")
        }
        let shown = PlaybackPositionText.visible(percent: percent)
        return Label(
            corner: shown, spoken: PlaybackPositionText.spoken(percent: percent),
            chapterDetail: kind == .media ? "Chapter · about \(shown)" : "Chapter · \(shown)")
    }

    /// The whole percent the listener is through a media item, rounded down so 99.6% shows 99% until the item is finished.
    /// Nil when the duration is not known, so no number is made up.
    public static func mediaPercent(currentMs: Int, durationMs: Int?) -> Int? {
        durationMs.flatMap { PlaybackPositionText.percent(position: currentMs, length: $0) }
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
