import Foundation

/// What a tapped Find in text result does (#5035). The engine's text seek throws unless the item is the loaded
/// session, so a result on any other item first opens it through the Timeline's own call, then seeks.
public enum FindInTextSeekPlan: Equatable, Sendable {
    /// The player holds this item: seek where it is (a paused player stays paused).
    case seekInPlace
    /// The player holds another item, or none: open the item first, then seek.
    case openThenSeek

    /// `loadedItemId` is the player snapshot's item; `selectedItemId` is the item the sheet searched.
    public static func plan(loadedItemId: String?, selectedItemId: String) -> FindInTextSeekPlan {
        loadedItemId == selectedItemId ? .seekInPlace : .openThenSeek
    }

    /// Whether the text seek may run now. `SessionEngine.seekText` never checks item ids: it moves whatever session is
    /// loaded and saves that position. So the seek runs only when the loaded item is the one the sheet searched, both
    /// on the in-place path and after an open (which may have returned early at the Terms gate, or thrown).
    public static func shouldSeek(loadedItemId: String?, searchedItemId: String) -> Bool {
        guard let loadedItemId, !loadedItemId.isEmpty else { return false }
        return loadedItemId == searchedItemId
    }
}

/// The words and shapes of the "Find in text" sheet (#5035), kept out of the view so they can be host-tested.
/// Presentation only: it reads a finished `ItemTextSearch.Result` and changes nothing.
public enum FindInTextPresentation {
    public static let fieldPlaceholder = "Find in text"
    public static let noMatchesText = "No matches in this text"
    public static let preparingText = "Still preparing the text"
    public static let buttonLabel = "Find in text"

    /// Whether the player's Timeline pane shows the button, and whether it can be tapped (Design 1, 6).
    public enum ButtonState: Equatable, Sendable {
        /// Recorded audio with no stored text to search (a podcast without a transcript).
        case hidden
        /// A text item whose text has not been stored yet.
        case preparing
        case available
    }

    /// `isRecordedAudio` is `ItemDetailState.isNativeAudio`; `text` is the item's stored text.
    public static func buttonState(isRecordedAudio: Bool, text: String) -> ButtonState {
        if isRecordedAudio { return .hidden }
        return text.isEmpty ? .preparing : .available
    }

    /// "Showing the first 100" when more matches exist than the cap, else nil.
    public static func capText(for result: ItemTextSearch.Result) -> String? {
        result.hasMore ? "Showing the first \(ItemTextSearch.maxMatches)" : nil
    }

    /// What the list shows for a typed query: nothing until the query has a character, then matches or the
    /// no-match line.
    public static func emptyText(query: String, result: ItemTextSearch.Result) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, result.matches.isEmpty else { return nil }
        return noMatchesText
    }

    /// An excerpt cut into the three runs the row draws, the middle one in bold. Ellipses mark a cut end.
    public struct ExcerptRuns: Equatable, Sendable {
        public var before: String
        public var match: String
        public var after: String
    }

    public static func excerptRuns(for match: ItemTextSearch.Match) -> ExcerptRuns {
        let chars = Array(match.excerpt)
        let start = min(max(match.excerptMatchStart, 0), chars.count)
        let end = min(max(match.excerptMatchEnd, start), chars.count)
        return ExcerptRuns(
            before: (match.excerptTruncatedBefore ? "\u{2026}" : "") + String(chars[..<start]),
            match: String(chars[start..<end]),
            after: String(chars[end...]) + (match.excerptTruncatedAfter ? "\u{2026}" : ""))
    }

    /// The row's heading: the chapter title, or nil for an item with no chapters.
    public static func heading(for match: ItemTextSearch.Match) -> String? {
        guard let title = match.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// VoiceOver: chapter, "In Table 2 (not read aloud)" when it applies, the excerpt, then the action (Design 8).
    public static func accessibilityLabel(for match: ItemTextSearch.Match) -> String {
        let runs = excerptRuns(for: match)
        var parts: [String] = []
        if let heading = heading(for: match) { parts.append(heading) }
        if let note = match.notReadAloudDescription { parts.append(note) }
        parts.append(runs.before + runs.match + runs.after)
        parts.append("double-tap to play from here")
        return parts.joined(separator: ", ")
    }
}
