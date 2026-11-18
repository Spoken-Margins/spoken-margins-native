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

    /// In ordinary playback no sequence is running: a Margin that plays as the episode reaches it has had no run-up.
    /// The press starts a review of that one Margin with a run-up of `plan.leadInMs`. The Margin carries the length itself,
    /// because a sender's own length would otherwise win over the review's. The episode plays on after it.
    public static func review(itemId: String, margin: MarginMomentAnchor, plan: Plan) -> MarginMomentSequence? {
        let lengthened = MarginMomentAnchor(
            marginId: margin.marginId, mediaTimeMs: margin.mediaTimeMs, label: margin.label,
            isApproximate: margin.isApproximate, caption: margin.caption, isYours: margin.isYours,
            isReadAloud: margin.isReadAloud, leadInMs: nil)
        return MarginMomentSequence(itemId: itemId, reviewing: [lengthened], leadInMs: plan.leadInMs)
    }
}
