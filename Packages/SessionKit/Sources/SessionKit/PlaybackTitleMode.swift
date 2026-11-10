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

    /// The separate show-name line under the title. The compact title already shows the show name, so it is drawn
    /// only with the full title, and the show appears once (#3598).
    public var showsSeparateShowLine: Bool { self == .full }

    /// The small line. VoiceOver keeps reading the full title.
    public static func compactLine(title: String, sourceName: String?) -> String {
        let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? title : name
    }

    /// The names Voice Control answers to on the title button. The button's accessibility label stays the full title
    /// (the journeys compare it), so in compact mode the drawn words must be added as input labels, or "Tap The Show"
    /// matches nothing (the #3849 class).
    public func voiceControlNames(title: String, sourceName: String?) -> [String] {
        let drawn = self == .compact ? Self.compactLine(title: title, sourceName: sourceName) : title
        var names: [String] = []
        for name in [drawn, title] where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        return names
    }
}
