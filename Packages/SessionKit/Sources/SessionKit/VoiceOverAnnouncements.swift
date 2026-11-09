import Foundation

/// What VoiceOver should say when part of a screen changes in place and focus stays where it was (#3728, after #1914).
/// The words and the "say it now?" rules are pure so host tests can pin them; the views only post what these return.
public enum VoiceOverAnnouncements {
    /// What the Margin card's `onChange` watches (#3728). It carries the Margin's id as well as the card because a waiting
    /// card holds only the sender, stage, position and noun: two single-Margin packets from one sender give two equal cards,
    /// and SwiftUI never calls `onChange` for equal values. With the id in the key, a different Margin is a different value.
    public struct CardKey: Equatable, Sendable {
        public var card: PinnedMarginCard?
        /// The Margin the card is about: the pending or playing prompt's interjection id.
        public var marginID: String?

        public init(card: PinnedMarginCard?, marginID: String?) {
            self.card = card
            self.marginID = marginID
        }
    }

    /// The Margin card on Now. A friend's Margin that waits for a tap, or one that could not play, appears at the top of
    /// the screen in silence. Returns the card's headline and its one line ("Margin from Cole is here. Tap Listen to
    /// hear it.") when the card has just *entered* one of those two stages or another Margin has replaced it in the same
    /// stage, and nil on every other change (the same card redrawn, a stage that speaks for itself, no card).
    ///
    /// - `playsByItself`: this card's Margin is guided (auto-play), so it waits only a beat (420 ms) and then plays
    ///   aloud. Telling the listener to tap a button they don't need would talk over the voice, so it is silent. A failure
    ///   is announced either way.
    public static func marginCard(from previous: CardKey?, to key: CardKey, playsByItself: Bool = false) -> String? {
        guard let card = key.card, needsAnnouncement(card.stage), !(playsByItself && card.stage == .waitingForTap) else { return nil }
        if let before = previous?.card, sameKind(before.stage, card.stage),
           before.subject == card.subject, before.position == card.position, previous?.marginID == key.marginID {
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

    /// The sender's sharing sheet swaps its stage in place (choose, review, recipient preview, share) while focus can stay
    /// on the bottom button, whose meaning changes with the stage (#3728). The stages are named here, not by the app's own
    /// enum, so the words can be tested on the host; the view shows the same `title` as the stage's heading.
    public enum SharingStep: String, CaseIterable, Sendable {
        case select, review, recipientPreview, share

        /// The stage's heading on screen, and what VoiceOver says when the sheet arrives at it.
        public var title: String {
            switch self {
            case .select: "Choose Margins"
            case .review: "Review selected Margins"
            case .recipientPreview: "Recipient preview"
            case .share: "Share your Margins"
            }
        }
    }

    /// What to say when the sharing sheet moves from one stage to another: the new stage's heading. Nil when the stage
    /// did not change (the sheet redrew), so nothing repeats. The first stage is not announced here: the sheet opening is
    /// a screen change in itself.
    public static func sharingStage(from previous: SharingStep, to step: SharingStep) -> String? {
        previous == step ? nil : step.title
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
