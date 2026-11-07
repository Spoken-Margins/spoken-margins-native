import Foundation

/// How the Now screen draws the source title (#3598). While the pinned Margin card holds its slot, which it does for
/// the whole of a friend's listen, countdown between Margins included, the big title gives way to one small line.
/// The mode follows whether the slot is held, never the card's stage, so the title changes once when the listen starts
/// and once when it ends, and never per card (#3220).
public enum PlaybackTitleMode: Equatable, Sendable {
    case full
    /// One small line: the show or source name when known, else the title itself.
    case compact

    public static func choose(cardSlotHeld: Bool) -> PlaybackTitleMode {
        cardSlotHeld ? .compact : .full
    }

    /// The small line. VoiceOver keeps reading the full title.
    public static func compactLine(title: String, sourceName: String?) -> String {
        let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? title : name
    }

    /// The Now title's VoiceOver hint, in the listener's word for what is open.
    public static func detailsHint(noun: SourceNoun?) -> String {
        "Opens details and listening history for this \(noun?.inSentence ?? "source")"
    }
}
