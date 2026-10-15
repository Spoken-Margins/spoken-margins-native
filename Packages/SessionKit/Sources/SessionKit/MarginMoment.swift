import Foundation

/// Whether forward playback reached a position between two progress ticks.
/// Shared by imported (shared) Margins and "Play this moment", so both agree on what "reached" means.
public enum PlaybackAnchorCrossing {
    /// True when playback moved forward from `before` to `after` and passed `anchor` on the way.
    /// When `maxForwardMs` is set, a larger move is treated as a seek or skip and crosses nothing.
    public static func isCrossed(anchor: Int, before: Int?, after: Int?, maxForwardMs: Int? = nil) -> Bool {
        guard let before, let after, after > before else { return false }
        if let maxForwardMs, after - before > maxForwardMs { return false }
        return before <= anchor && anchor <= after
    }
}

/// A listener's own spoken Margin at its media position, for inline playback.
public struct MarginMomentAnchor: Sendable, Equatable {
    public let marginId: String
    public let mediaTimeMs: Int

    public init(marginId: String, mediaTimeMs: Int) {
        self.marginId = marginId
        self.mediaTimeMs = mediaTimeMs
    }
}

/// "Play this moment" (#159): start a lead-in before the chosen Margin, play that Margin inline when
/// playback reaches it, then keep listening and play the listener's other Margins on the item as they come up.
///
/// This is the whole state machine. The app supplies progress ticks and plays the voices.
public struct MarginMomentSequence: Sendable, Equatable {
    public static let defaultLeadInMs = ListeningMoment.rule(for: .playThisMoment).leadInMs
    /// Progress ticks arrive every 0.5 s, so even 3× playback advances well under this. A bigger forward move
    /// is a seek or skip, and skipping over a Margin shouldn't play it.
    public static let maxTickAdvanceMs = 4_000
    /// The same limit for this moment's clock; a text clock reads in characters, so its limit differs (see `MarginMomentClock`).
    public let tickAdvanceLimitMs: Int

    public enum Phase: Sendable, Equatable {
        case leadIn
        case playingMargin(String)
        case listening
    }

    public let itemId: String
    public let target: MarginMomentAnchor
    public let startMediaTimeMs: Int
    public private(set) var phase: Phase = .leadIn
    /// Margins not yet played, in playback order.
    public private(set) var unplayed: [MarginMomentAnchor]
    /// The Margin whose voice has the floor, with its place in the source (#866: Add Margin records there).
    public private(set) var playing: MarginMomentAnchor?

    /// `otherMargins` are the item's spoken Margins when the moment starts. Margins recorded later aren't
    /// included, so a new Margin never replays right after it's saved.
    public init(
        itemId: String,
        target: MarginMomentAnchor,
        otherMargins: [MarginMomentAnchor],
        leadInMs: Int = MarginMomentSequence.defaultLeadInMs,
        tickAdvanceLimitMs: Int = MarginMomentSequence.maxTickAdvanceMs
    ) {
        self.itemId = itemId
        self.target = target
        self.tickAdvanceLimitMs = tickAdvanceLimitMs
        let start = Self.leadInStartMediaTimeMs(forTarget: target, leadInMs: leadInMs)
        startMediaTimeMs = start
        let others = otherMargins.filter { $0.marginId != target.marginId && $0.mediaTimeMs >= start }
        unplayed = Self.inPlaybackOrder([target] + others)
    }

    /// The listener heard one of their own Margins from its detail and the source is coming back where it was (#1538).
    /// There is no lead-in and nothing to seek to: the item keeps playing from `position`, and its spoken Margins
    /// after that play as playback reaches them. `playedMargin` is the one just heard, so it never plays again.
    public init(
        itemId: String,
        resumingAtMediaTimeMs position: Int,
        playedMargin: MarginMomentAnchor,
        otherMargins: [MarginMomentAnchor],
        tickAdvanceLimitMs: Int = MarginMomentSequence.maxTickAdvanceMs
    ) {
        self.itemId = itemId
        self.tickAdvanceLimitMs = tickAdvanceLimitMs
        target = playedMargin
        startMediaTimeMs = position
        phase = .listening
        unplayed = Self.inPlaybackOrder(otherMargins.filter { $0.marginId != playedMargin.marginId && $0.mediaTimeMs > position })
    }

    /// Where the lead-in before `target` starts, by the single lead-in rule (#807).
    public static func leadInStartMediaTimeMs(forTarget target: MarginMomentAnchor, leadInMs: Int = defaultLeadInMs) -> Int {
        ListeningMoment(
            use: .playThisMoment,
            margin: ListeningMoment.Margin(id: target.marginId, position: target.mediaTimeMs),
            source: .media(),
            leadInMs: leadInMs
        ).sourceStartPosition
    }

    private static func inPlaybackOrder(_ margins: [MarginMomentAnchor]) -> [MarginMomentAnchor] {
        margins.sorted { lhs, rhs in
            lhs.mediaTimeMs == rhs.mediaTimeMs ? lhs.marginId < rhs.marginId : lhs.mediaTimeMs < rhs.mediaTimeMs
        }
    }

    public var isPlayingMargin: Bool {
        if case .playingMargin = phase { return true }
        return false
    }

    /// Time left before the chosen Margin plays, while it is still ahead. Drives the "coming up" cue.
    public func msUntilTarget(currentMediaTimeMs: Int?) -> Int? {
        guard phase == .leadIn, let current = currentMediaTimeMs, current <= target.mediaTimeMs else { return nil }
        return target.mediaTimeMs - current
    }

    /// The coming-up card's source-time countdown, rounded up to avoid promising an early arrival.
    /// Before the first progress reading, show the planned lead-in rather than hiding the cue.
    public func targetCountdown(currentMediaTimeMs: Int?) -> String? {
        guard let ms = msUntilTarget(currentMediaTimeMs: currentMediaTimeMs ?? startMediaTimeMs) else { return nil }
        let seconds = ms / 1_000 + (ms % 1_000 == 0 ? 0 : 1)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Call on each progress tick while the source plays. Returns the Margin to play now, if playback just
    /// reached one. Margins crossed in the same tick are consumed; the first plays.
    public mutating func progressed(from before: Int?, to after: Int?) -> MarginMomentAnchor? {
        guard !isPlayingMargin else { return nil }
        let crossed = unplayed.filter {
            PlaybackAnchorCrossing.isCrossed(
                anchor: $0.mediaTimeMs, before: before, after: after, maxForwardMs: tickAdvanceLimitMs
            )
        }
        guard let first = crossed.first else { return nil }
        let crossedIDs = Set(crossed.map(\.marginId))
        unplayed.removeAll { crossedIDs.contains($0.marginId) }
        phase = .playingMargin(first.marginId)
        playing = first
        return first
    }

    /// "Play it now" during the lead-in: skip the rest of the lead-in and play the chosen Margin.
    public mutating func jumpToTarget() -> MarginMomentAnchor? {
        guard phase == .leadIn, unplayed.contains(target) else { return nil }
        unplayed.removeAll { $0.mediaTimeMs < target.mediaTimeMs || $0 == target }
        phase = .playingMargin(target.marginId)
        playing = target
        return target
    }

    /// The Margin's voice ended, was skipped, or couldn't play. The source continues.
    public mutating func marginFinished() {
        guard isPlayingMargin else { return }
        playing = nil
        phase = unplayed.contains(target) ? .leadIn : .listening
    }
}

extension Interjection {
    /// A spoken Margin on the item with a saved voice, wherever it is anchored: a media time, or only a text place
    /// (a Margin made while an article was read aloud on the device has no media time, #1577).
    public var isSpokenItemMargin: Bool {
        status == "active" && captureKind != .written && targetType == .item && audioPath != nil
    }

    /// A spoken Margin on the item with a media time and a saved voice, which a Margin moment plays inline.
    public var isInlineSpokenMargin: Bool {
        isSpokenItemMargin && anchor.mediaTimeMs != nil
    }
}

extension CompactControlCommand {
    /// The command changes where the source stands (a skip, a scrub, a chapter jump). Lock Screen, headphone, Watch and
    /// CarPlay commands arrive through the compact controls rather than the app's own skip and seek methods, so the
    /// app tells a running Margin moment about each of these (#1656): the next reading is a new place, not playback
    /// reaching a Margin it jumped over. Listed without a default so a new command has to choose.
    public var movesPlaybackPosition: Bool {
        switch self {
        case .skipBack, .skipForward, .skimBackward, .skimForward, .seekToMediaTime, .jumpToChapter: true
        case .play, .pause, .togglePlayPause, .setPlaybackRate, .beginInterjection, .finishInterjection,
             .cancelInterjection, .generateInterjectionSummary, .submitFollowup: false
        }
    }
}
