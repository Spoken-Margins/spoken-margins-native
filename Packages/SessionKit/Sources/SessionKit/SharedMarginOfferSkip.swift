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

    /// How many not-yet-announced Margins this tick crossed that `nextOffer` would have lost: the Margins it would
    /// have offered had the slot been free. It follows that rule exactly, so the event never names a Margin the queue
    /// still holds, and never misses one the queue drops (#4109 audit):
    /// - A forward jump still crosses a Margin. `nextOffer` only clears the Margins already waiting on a jump and then
    ///   looks for crossings without a step limit (a Lock Screen skip, or a long gap between ticks while locked), so
    ///   this does not filter jumps either.
    /// - A Margin in `fresh` reveal mode is never offered, so it is not counted.
    /// - A Margin that plays after the others crosses at the end of the episode, and `nextOffer` queues it for later
    ///   when the slot is busy (#4347) instead of dropping it, so it is not counted.
    /// Zero for another item than the selected one.
    public static func crossedCount(
        previous: SessionSnapshot, current: SessionSnapshot, selectedItemID: String, prompts: [ImportedCommentaryPrompt]
    ) -> Int {
        guard current.itemId == selectedItemID else { return 0 }
        return SharedMarginPrompts.crossed(prompts: prompts, previous: previous, current: current)
            .filter { $0.layer.revealMode != .fresh && $0.plan != .afterOthers }.count
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
