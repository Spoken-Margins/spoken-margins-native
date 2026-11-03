import Foundation

/// What the item screen offers for starting to listen, and what each control is called (#3219).
///
/// An item with Margins a friend sent that the listener hasn't heard used to offer four ways in: a button reading
/// "Continue" (or "Start listening", "Replay", "Listen now"), a "New Margins to hear" dialog behind it, and
/// "Review new Margins" and "Review Margins" side by side. A friend who had just imported a packet could not tell
/// which to tap (owner, 2026-11-02). With unheard friend Margins the screen now offers two choices whose words never
/// change: play the episode with the Margins playing in place (the 2026-10-31 call, #3059), or hear just the Margins,
/// each with its lead-in. Everything else keeps today's single button and words.
public struct ItemListeningChoices: Equatable, Sendable {
    public static let playWithMarginsTitle = "Play episode with Margins"
    public static let marginsOnlyTitle = "Hear just the Margins"

    /// The big button's words.
    public let primaryTitle: String
    /// The second choice's words. Nil when the item has no unheard friend Margins, so there is nothing to choose.
    public let marginsOnlyTitle: String?
    /// What VoiceOver reads for the second choice: the words, then how many Margins are waiting.
    public let marginsOnlyAccessibilityLabel: String?
    /// True when the big button starts the episode directly, with friend Margins playing in place, instead of
    /// asking "hear new Margins first?" (the dialog the two choices replace).
    public let skipsNewMarginsQuestion: Bool

    /// - Parameters:
    ///   - unheardFriendMarginCount: the friend Margins on this item that the listener can hear and hasn't.
    ///   - hasFinishedSession: the item's session reached its end, so the plain button says "Replay".
    ///   - hasContinuationSession: the item has a session to carry on, so the plain button says "Continue".
    ///   - isPreparingAudio: the item's audio is still being made or fetched, so the plain button says "Listen now".
    public init(
        unheardFriendMarginCount: Int,
        hasFinishedSession: Bool,
        hasContinuationSession: Bool,
        isPreparingAudio: Bool
    ) {
        if unheardFriendMarginCount > 0 {
            // The same words whether or not the episode was heard, started or is still being prepared: the two
            // choices describe what will play, not where the listener is in the item.
            primaryTitle = Self.playWithMarginsTitle
            marginsOnlyTitle = Self.marginsOnlyTitle
            marginsOnlyAccessibilityLabel = unheardFriendMarginCount == 1
                ? "\(Self.marginsOnlyTitle), 1 new Margin"
                : "\(Self.marginsOnlyTitle), \(unheardFriendMarginCount) new Margins"
            skipsNewMarginsQuestion = true
        } else {
            if isPreparingAudio {
                primaryTitle = "Listen now"
            } else if hasFinishedSession {
                primaryTitle = "Replay"
            } else {
                primaryTitle = hasContinuationSession ? "Continue" : "Start listening"
            }
            marginsOnlyTitle = nil
            marginsOnlyAccessibilityLabel = nil
            skipsNewMarginsQuestion = false
        }
    }
}
