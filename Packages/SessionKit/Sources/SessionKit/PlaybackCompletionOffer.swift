import Foundation

/// #2393: when the playback screen offers "Mark complete".
///
/// A listener who is nearly done should not have to leave the item and swipe it in the Library, and the control
/// should not crowd the playback controls before then. For a text source or PDF the offer starts where the body
/// ends: the first reference list or back matter. "A lot of PDFs, the bibliographies start like 60% of the way
/// through" (owner, 2026-10-21), so a fixed fraction would offer it too late. A source with no such part, and a
/// podcast, offer it from `fallbackFraction`.
public enum PlaybackCompletionOffer {
    /// Where an item with no recognised end of body, or a podcast, starts offering completion.
    public static let fallbackFraction = 0.75

    /// Where completion is offered whatever the structure says. A back-matter part near the very end (a footer, a
    /// comments link) must not hold the offer back until the item is over (#2968).
    public static let lateFraction = 0.9

    /// A reference list this early is a misread (a short list quoted at the top), not the end of the body.
    static let earliestBodyEndFraction = 0.25

    /// The character offset where the body of `source` has ended: its first reference or back-matter part, when that
    /// comes after the first quarter of the text. Nil when the source has none.
    public static func bodyEnd(in source: TimelineSourceContent) -> Int? {
        guard source.characterCount > 0 else { return nil }
        let earliest = Int((Double(source.characterCount) * earliestBodyEndFraction).rounded(.up))
        return source.entries.first { ($0.role == .reference || $0.role == .backMatter) && $0.start >= earliest }?.start
    }

    /// Whether to offer completion at character `offset` of a text of `length` characters.
    public static func isOffered(textOffset offset: Int, textLength length: Int, source: TimelineSourceContent) -> Bool {
        guard length > 0, offset >= 0 else { return false }
        // The common case, early in the item, costs one comparison.
        guard Double(offset) >= Double(length) * earliestBodyEndFraction else { return false }
        if Double(offset) >= Double(length) * lateFraction { return true }
        if source.characterCount == length, let end = bodyEnd(in: source) { return offset >= end }
        return Double(offset) >= Double(length) * fallbackFraction
    }

    /// Whether to offer completion at `timeMs` of a podcast or other audio of `durationMs`.
    public static func isOffered(mediaTimeMs timeMs: Int, durationMs: Int) -> Bool {
        guard durationMs > 0, timeMs >= 0 else { return false }
        return Double(timeMs) >= Double(durationMs) * fallbackFraction
    }

    /// What the playback screen shows for completion once the position test has run.
    public enum Presence: String, Equatable, Sendable {
        /// The playhead is before the point where completion is offered.
        case notYet
        /// The button shows.
        case offered
        /// The position says offer, but the Library has no row for the playing item.
        case noLibraryRow
        /// The position says offer, but the row is complete (finished by listening) and has no completion action.
        case alreadyComplete
    }

    /// Joins the position test with the Library row. The playback screen names the reason when the button is
    /// hidden past the position test, because the owner saw it missing at 96% with no way to tell why (#2968).
    public static func presence(positionOffered: Bool, row: LibraryItemRow?) -> Presence {
        guard positionOffered else { return .notYet }
        guard let row else { return .noLibraryRow }
        return ItemQuickAction.completionAction(for: row) == .markComplete ? .offered : .alreadyComplete
    }
}
