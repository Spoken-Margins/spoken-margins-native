import Foundation

/// A friend's Margin the source crossed while the offer slot was taken, so it was never offered (#4109).
///
/// `SharedMarginOfferQueue.nextOffer` offers nothing while a card is up, a friend's Margin voice plays, a review runs
/// or a moment's voice speaks, and what crosses in that window is not announced and does not cross again. The owner
/// heard friend Margins miss with the screen locked and the cause is not known: this names the window in the export
/// ("crossed, not offered, why") so a device run can say whether a stuck card or voice swallowed them. Pure; the
/// event carries counts and flags only, never a title, an id or any text.
public enum SharedMarginOfferSkip {
    /// What held the slot when the Margins crossed.
    public struct Slot: Equatable, Sendable {
        public var pendingCard: Bool
        public var playingVoice: Bool
        public var reviewRunning: Bool
        public var momentVoice: Bool

        public init(pendingCard: Bool, playingVoice: Bool, reviewRunning: Bool, momentVoice: Bool) {
            self.pendingCard = pendingCard
            self.playingVoice = playingVoice
            self.reviewRunning = reviewRunning
            self.momentVoice = momentVoice
        }
    }

    /// How many not-yet-announced Margins this tick crossed. Counted by the rule `nextOffer` uses, and a Margin in
    /// `fresh` reveal mode is never offered, so it is not counted. Zero for another item than the selected one.
    public static func crossedCount(
        previous: SessionSnapshot, current: SessionSnapshot, selectedItemID: String, prompts: [ImportedCommentaryPrompt]
    ) -> Int {
        guard current.itemId == selectedItemID, !SharedMarginOfferQueue.isPlayheadJump(previous: previous, current: current) else { return 0 }
        return SharedMarginPrompts.crossed(prompts: prompts, previous: previous, current: current)
            .filter { $0.layer.revealMode != .fresh }.count
    }

    /// The developer event `margin.shared_offer_skipped`. Field names are pinned by a host test.
    public static func eventFields(crossed: Int, slot: Slot, appState: String, sourcePlaying: Bool) -> [String: String] {
        [
            "crossed": String(crossed),
            "slotPendingCard": String(slot.pendingCard),
            "slotPlayingVoice": String(slot.playingVoice),
            "slotReview": String(slot.reviewRunning),
            "slotMomentVoice": String(slot.momentVoice),
            "appState": appState,
            "sourcePlaying": String(sourcePlaying),
        ]
    }

    /// The one line `diagnostics["lastSharedMarginSkipped"]` keeps.
    public static func diagnosticsLine(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: ";")
    }
}
