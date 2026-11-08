import Foundation

/// What VoiceOver should say when part of a screen changes in place and focus stays where it was (#3728, after #1914).
/// The words and the "say it now?" rules are pure so host tests can pin them; the views only post what these return.
public enum VoiceOverAnnouncements {
    /// The Margin card on Now. A friend's Margin that waits for a tap, or one that could not play, appears at the top of
    /// the screen in silence; a guided Margin plays aloud and needs no announcement. Returns the card's headline and
    /// its one line ("Margin from Cole is here. Tap Listen to hear it.") when the card has just *entered* one of those
    /// two stages, and nil on every other change: the same stage again (the headline's countdown ticks twice a second),
    /// a stage that speaks for itself, or no card.
    public static func marginCard(from previous: PinnedMarginCard?, to card: PinnedMarginCard?) -> String? {
        guard let card, needsAnnouncement(card.stage) else { return nil }
        if let previous, sameKind(previous.stage, card.stage) { return nil }
        return "\(card.headline). \(card.detail)"
    }

    private static func needsAnnouncement(_ stage: PinnedMarginCard.Stage) -> Bool {
        switch stage {
        case .waitingForTap, .failed: true
        default: false
        }
    }

    private static func sameKind(_ a: PinnedMarginCard.Stage, _ b: PinnedMarginCard.Stage) -> Bool {
        switch (a, b) {
        case (.waitingForTap, .waitingForTap), (.failed, .failed): true
        default: false
        }
    }

    /// The Reader's chapter step (Previous or Next chapter replaces the text and the heading under the pressed button):
    /// "Chapter 2 of 7, The Method". Without a position (no chapters, or a chapter that can't be placed) the title alone;
    /// nil when there is nothing to say. A position of "1 of 1" is never spoken, as on screen.
    public static func readerChapter(position: (number: Int, count: Int)?, title: String?) -> String? {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let position, position.count > 1, position.number >= 1, position.number <= position.count else { return name }
        let place = "Chapter \(position.number) of \(position.count)"
        return name.map { "\(place), \($0)" } ?? place
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
