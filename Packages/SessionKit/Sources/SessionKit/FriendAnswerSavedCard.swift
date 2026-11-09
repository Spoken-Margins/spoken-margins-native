import Foundation

/// The card after a friend saves a Margin of their own on a friend's item (#3247). The owner chose that Share keeps its
/// name (2026-11-03), so this card carries the news that the Margin can go back: "Your Margin is saved at 39:40. To send
/// it to Cole, tap Share below. You pick which of your Margins go." It sits in the pinned card's fixed slot, so it adds
/// no button and moves nothing.
extension PinnedMarginCard {
    /// How long the card keeps the slot after the save. A Default taken: long enough to read twice, short enough that the
    /// countdown to the next Margin comes back by itself.
    public static let answerSavedWindow: TimeInterval = 45

    /// The card for the listener's newest Margin on an item that holds a friend's packet, until `answerSavedWindow` has
    /// passed. Nil on the listener's own items (no live friend layer), when nothing was made since the friend's packet
    /// arrived, and once the window is over. `localMargins` and `layers` are the open item's.
    public static func answerSaved(now: Date, localMargins: [Interjection], layers: [ImportedCommentaryLayer]) -> PinnedMarginCard? {
        guard let offer = ReplyBackOffer.make(localMargins: localMargins, layers: layers),
              let saved = offer.candidates.last else { return nil }
        let age = now.timeIntervalSince(saved.createdAt)
        guard age >= 0, age < answerSavedWindow else { return nil }
        return PinnedMarginCard(subject: .yours, stage: .answerSaved(atMs: saved.anchor.mediaTimeMs, sentTo: offer.friendName))
    }
}
