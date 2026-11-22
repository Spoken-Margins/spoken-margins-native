import Foundation

/// A position in an item, said in the item's own unit: the clock on media, a percentage on text. The playback
/// screen's scrubber shows the same numbers, so what VoiceOver reads for a Skim stop and what the Timeline shows
/// can't disagree (#3986, #3862). `visible` is the short form for the eye ("1:07:30", "65%"), `spoken` the form
/// VoiceOver reads ("1 hour, 7 minutes, 30 seconds", "65 percent").
public enum PlaybackPositionText {
    /// "7:30", or "1:07:30" from an hour on. Negative times read as 0:00.
    public static func visible(ms: Int) -> String {
        let seconds = max(0, ms) / 1_000
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return seconds >= 3_600
            ? "\(seconds / 3_600):\(two(seconds / 60 % 60)):\(two(seconds % 60))"
            : "\(seconds / 60):\(two(seconds % 60))"
    }

    /// "1 hour, 7 minutes, 30 seconds". Units that are zero are left out ("7 minutes, 30 seconds", "1 hour"),
    /// and a time under a second is "0 seconds".
    public static func spoken(ms: Int) -> String {
        let seconds = max(0, ms) / 1_000
        let parts = [(seconds / 3_600, "hour"), (seconds / 60 % 60, "minute"), (seconds % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: ", ")
    }

    /// The whole percent a character position is through a text of `length` characters, rounded down and kept
    /// between 0 and 100. Nil when the length is not known (zero or less), so no number is made up.
    public static func percent(position: Int, length: Int) -> Int? {
        guard length > 0 else { return nil }
        let clamped = min(max(0, position), length)
        return Int((Double(clamped) * 100 / Double(length)).rounded(.down))
    }

    /// "65%".
    public static func visible(percent: Int) -> String { "\(min(max(0, percent), 100))%" }

    /// "65 percent".
    public static func spoken(percent: Int) -> String { "\(min(max(0, percent), 100)) percent" }
}
