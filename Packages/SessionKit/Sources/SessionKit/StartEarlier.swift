import Foundation

/// "Start a minute earlier" (#4171): the listener hears a Margin that makes no sense yet, and asks for one more minute of
/// the episode before it. The rule is here, so the card, the model and the tests read one definition.
///
/// The new run-up is the one just used plus a minute, starting at `max(0, margin - runUp)`. Each press adds another
/// minute. Once the run-up reaches the start of the episode there is nothing earlier, and no button is offered.
public enum StartEarlier {
    public static let stepMs = 60_000

    public struct Plan: Sendable, Equatable {
        public let marginId: String
        /// The run-up to play now: the one used just now, and a minute.
        public let leadInMs: Int
        /// Where the source starts: `max(0, margin - leadInMs)`.
        public let startMediaTimeMs: Int
    }

    /// The plan for `margin` after a run-up of `runUpMs` (zero when the Margin played in ordinary playback, with none).
    /// Nil when that run-up already started at the beginning of the episode.
    public static func plan(for margin: MarginMomentAnchor, runUpMs: Int) -> Plan? {
        let used = max(0, runUpMs)
        guard margin.mediaTimeMs - used > 0 else { return nil }
        let lengthened = used + stepMs
        return Plan(marginId: margin.marginId, leadInMs: lengthened, startMediaTimeMs: max(0, margin.mediaTimeMs - lengthened))
    }

    /// What a press on a friend's Margin playing by itself reviews: that Margin, then the friend's Margins crossed in the
    /// same tick that still wait their turn behind it (`SharedMarginOfferQueue.waitingIDs`, #918), in waiting order. The
    /// longer run-up moves the playhead back, which empties that queue, and they are already announced, so the episode
    /// crossing them again would not offer them: left out, they would never play (audit on #5093). A Margin with no place
    /// in the episode, or one no longer offered, is left out.
    public static func entries(
        playing: ImportedCommentaryPrompt, waiting ids: [String], among prompts: [ImportedCommentaryPrompt]
    ) -> [SharedMarginReview.Entry] {
        let waiting = ids.filter { $0 != playing.id }.compactMap { id in prompts.first { $0.id == id } }
        return ([playing] + waiting).compactMap(entry(for:))
    }

    private static func entry(for prompt: ImportedCommentaryPrompt) -> SharedMarginReview.Entry? {
        guard let ms = prompt.mediaTimeMs else { return nil }
        let isApproximate: Bool
        if case .roughly = prompt.plan { isApproximate = true } else { isApproximate = false }
        return SharedMarginReview.Entry(layer: prompt.layer, interjection: prompt.interjection, mediaTimeMs: ms, isApproximate: isApproximate)
    }

    /// In ordinary playback no sequence is running: a Margin that plays as the episode reaches it has had no run-up.
    /// The press starts a review of that one Margin with a run-up of `plan.leadInMs`. The Margin carries the length itself,
    /// because a sender's own length would otherwise win over the review's. The episode plays on after it.
    public static func review(itemId: String, margin: MarginMomentAnchor, plan: Plan) -> MarginMomentSequence? {
        review(itemId: itemId, margins: [margin], plan: plan)
    }

    /// The same review over the steps the app's review builds for that Margin (a friend's reply is played after the
    /// listener's own Margin it answers, #3221). Every step drops its sender length, so the run-up is `plan.leadInMs`.
    /// `returnToMediaTimeMs` is where the source stood when the press came; the review plays on from the Margin unless
    /// the listener's place was beyond it (`MarginMomentSequence.marginFinished`).
    public static func review(
        itemId: String, margins: [MarginMomentAnchor], returnToMediaTimeMs: Int? = nil, plan: Plan
    ) -> MarginMomentSequence? {
        let lengthened = margins.map { margin in
            MarginMomentAnchor(
                marginId: margin.marginId, mediaTimeMs: margin.mediaTimeMs, label: margin.label,
                isApproximate: margin.isApproximate, caption: margin.caption, isYours: margin.isYours,
                isReadAloud: margin.isReadAloud, leadInMs: nil)
        }
        return MarginMomentSequence(
            itemId: itemId, reviewing: lengthened, returnToMediaTimeMs: returnToMediaTimeMs, resumesAtEnd: true,
            leadInMs: plan.leadInMs)
    }
}
