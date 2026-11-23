import Foundation

extension HearItLand {
    /// The Margin moment hear it land plays (#4713): the one lead-in row for it (`ListeningMoment.Use.hearItLand`), and
    /// **no other Margins**. With none, the sequence is `.listening` with nothing unplayed once the voice ends, so the
    /// card goes (`Gate1AppModel.startMarginMoment`'s onChange) instead of keeping an "up next" slot that would hide a
    /// friend's answer-saved card.
    public static func sequence(
        itemId: String,
        target: MarginMomentAnchor,
        tickAdvanceLimitMs: Int = MarginMomentSequence.maxTickAdvanceMs
    ) -> MarginMomentSequence {
        MarginMomentSequence(
            itemId: itemId,
            target: target,
            otherMargins: [],
            leadInMs: ListeningMoment.rule(for: .hearItLand).leadInMs,
            tickAdvanceLimitMs: tickAdvanceLimitMs
        )
    }
}

/// What hear it land leaves for the cards to read: which Margin's playback is running, when it ended (the friend's
/// answer-saved window counts from there), and a written Margin's saved card. A value type so the rules are host-tested;
/// the app keeps one in `HearItLandState`, not on `Gate1AppModel`.
public struct HearItLandAftermath: Equatable, Sendable {
    /// A playback that has not reported its end this long after it began is abandoned (left for another item, a
    /// recording, a route loss). A later end of that same Margin, by "Play this moment", must not reopen the card.
    public static let playbackSpan: TimeInterval = 120

    public struct Written: Equatable, Sendable {
        public let itemId: String
        public let atMs: Int?
        public let savedAt: Date
    }

    private var playingIdentity: String?
    private var playingStartedAt: Date?
    /// When the last hear-it-land playback ended. The answer-saved card's window counts from here.
    public private(set) var playbackEndedAt: Date?
    public private(set) var written: Written?

    public init() {}

    /// The playback of the Margin `identity` starts now.
    public mutating func began(identity: String, at now: Date) {
        playingIdentity = identity
        playingStartedAt = now
        playbackEndedAt = nil
    }

    /// The card's `Run` for a moment about `identity`: `.hearItLand` only while that Margin's own playback runs.
    public func run(forMomentTarget identity: String) -> PinnedMarginCard.Run {
        playingIdentity == identity ? .hearItLand : .moment
    }

    /// A moment's voice stopped, at its end or skipped. Counts only for the Margin this run began, once.
    public mutating func voiceEnded(identity: String, at now: Date) {
        guard playingIdentity == identity, let started = playingStartedAt else { return }
        playingIdentity = nil
        playingStartedAt = nil
        guard now.timeIntervalSince(started) <= Self.playbackSpan else { return }
        playbackEndedAt = now
    }

    /// A written first Margin was saved at `atMs` of `itemId`.
    public mutating func wrote(itemId: String, atMs: Int?, at now: Date) {
        written = Written(itemId: itemId, atMs: atMs, savedAt: now)
    }

    /// The card for a written first Margin on `itemId`, for `PinnedMarginCard.answerSavedWindow` after the save. Nil
    /// on another item and once the window is over.
    public func writtenCard(now: Date, itemId: String?) -> PinnedMarginCard? {
        guard let written, written.itemId == itemId else { return nil }
        let age = now.timeIntervalSince(written.savedAt)
        guard age >= 0, age < PinnedMarginCard.answerSavedWindow else { return nil }
        return PinnedMarginCard(subject: .yours, stage: .savedHere(atMs: written.atMs))
    }
}
