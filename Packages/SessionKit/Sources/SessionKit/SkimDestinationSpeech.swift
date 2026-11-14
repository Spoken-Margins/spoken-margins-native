import Foundation

/// What VoiceOver reads for the chapter row's arrows (#3986). The label is the action ("Skim forward") and the value
/// is where it goes ("Chapter 4: Alignment, 65 percent"). The old label ended in " by scene summary" on every Skim
/// arrow, which has been wrong since Skim began going to the next chapter or Margin with or without a Listening Map
/// (#460). Only words change here: this type is a pure function from an already-resolved destination, so the table in
/// the Design comment on #3986 is one test row each. The app resolves a Skim stop into a `Destination`
/// (chapters and Margin rows live in the app's item detail); nothing here reads app data.
public enum SkimDestinationSpeech {
    public enum Direction: Equatable, Sendable {
        case forward
        case backward
    }

    /// Where a Skim press would land, or why it can't.
    public enum Destination: Equatable, Sendable {
        /// The start of a chapter other than the current one, or the next chapter ahead, by its title.
        case chapter(title: String)
        /// Backward only: the start of the chapter now playing.
        case chapterStart
        /// One of the listener's own Margins.
        case ownMargin
        /// A friend's Margin. Nil, or a stand-in such as "Someone", reads as "A friend's Margin".
        case friendMargin(name: String?)
        /// A scene summary plays first, then the item carries on in the chapter or scene with this title.
        case summaryFirst(title: String)
        /// Nothing in that direction.
        case none
        /// The item's stops are still being read from the store.
        case loading
        /// A recording is in progress.
        case locked
    }

    public struct Speech: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public static func label(_ direction: Direction) -> String {
        direction == .forward ? "Skim forward" : "Skim back"
    }

    /// The speech for a Skim arrow. `position` is the stop's place in the item's own unit, already spoken
    /// (`PlaybackPositionText.spoken`), or nil when it isn't known; it is left out with its comma then.
    public static func skim(_ direction: Direction, to destination: Destination, position: String?) -> Speech {
        let value: String
        switch destination {
        case .chapter(let title): value = with(title, position)
        case .chapterStart: value = with("Start of this chapter", position)
        case .ownMargin: value = with("Your Margin", position)
        case .friendMargin(let name): value = with("\(friendPossessive(name)) Margin", position)
        case .summaryFirst(let title): value = with(title, "summary first", position)
        case .none: value = direction == .forward ? "Nothing ahead to skim to" : "Nothing behind to skim to"
        case .loading: value = "Still loading. Try again in a moment."
        case .locked: value = "Unavailable while recording"
        }
        return Speech(label: label(direction), value: value)
    }

    /// The arrow that stands in Skim's slot as a plain chapter jump when Skim can't be pressed (#2185). With a
    /// reason, the value is the reason's message; without one it is the destination, as for any Next chapter.
    public static func nextChapterInSkimSlot(
        reason: SkimUnavailableReason?, title: String, position: String?
    ) -> Speech {
        Speech(label: "Next chapter", value: reason?.message ?? with(title, position))
    }

    /// The plain Next chapter arrow.
    public static func nextChapter(title: String, position: String?) -> Speech {
        Speech(label: "Next chapter", value: with(title, position))
    }

    /// A chapter's own title, or "Chapter N" (1-based) when it has none.
    public static func chapterTitle(_ title: String?, index: Int) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Chapter \(index + 1)" : trimmed
    }

    /// "Sam's", or "A friend's" when the file names nobody (or only a stand-in).
    static func friendPossessive(_ name: String?) -> String {
        SharedPacketArrival.senderName(name).map { "\($0)'s" } ?? "A friend's"
    }

    private static func with(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
