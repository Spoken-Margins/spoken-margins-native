import Foundation

/// What VoiceOver should say when part of a screen changes in place and focus stays where it was (#3728, after #1914).
/// The words and the "say it now?" rules are pure so host tests can pin them; the views only post what these return.
public enum VoiceOverAnnouncements {
    /// The Margin card on Now. A friend's Margin that waits for a tap, or one that could not play, appears at the top of
    /// the screen in silence. Returns the card's headline and its one line ("Margin from Cole is here. Tap Listen to
    /// hear it.") when the card has just *entered* one of those two stages, and nil on every other change.
    ///
    /// - `playsByItself`: this card's Margin is guided (auto-play), so it waits only a beat (420 ms) and then plays
    ///   aloud. Telling the listener to tap a button they don't need would talk over the voice, so it is silent. A failure is announced either way.
    /// - `previousMarginID` / `marginID`: which Margin each card is about. A card replaced by another Margin in the same
    ///   stage (a second Margin crossed while a tone-only card waits, which only happens with VoiceOver or Switch Control
    ///   on) is a new card and is announced; the same stage for the same Margin again (the card is redrawn) is not.
    public static func marginCard(
        from previous: PinnedMarginCard?, to card: PinnedMarginCard?,
        playsByItself: Bool = false, previousMarginID: String? = nil, marginID: String? = nil
    ) -> String? {
        guard let card, needsAnnouncement(card.stage), !(playsByItself && card.stage == .waitingForTap) else { return nil }
        if let previous, sameKind(previous.stage, card.stage),
           previous.subject == card.subject, previous.position == card.position, previousMarginID == marginID {
            return nil
        }
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
