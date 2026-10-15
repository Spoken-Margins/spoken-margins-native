import Foundation

/// The clock "Play this moment" counts its lead-in on (#1577).
///
/// `MarginMomentSequence` counts milliseconds. A podcast, or an article playing prepared narration, has a media
/// clock for that. An article read aloud on the device has none: playback only knows how far through the text it
/// is, and its Margins are anchored by text position. For that source the moment counts narration time instead,
/// the written characters read a second at 1× (`ListeningTimeEstimator.defaultCharactersPerSecond`), so the one
/// lead-in rule (`ListeningMoment`, #807) and the countdown work the same way on every kind of item.
public enum MarginMomentClock: Sendable, Equatable {
    /// Positions are the source's media time in milliseconds.
    case media
    /// Positions are text offsets read by on-device speech, converted to milliseconds of narration at 1×.
    case narratedText(charactersPerSecond: Double)

    /// An article read aloud on the device at the typical rate.
    public static let liveNarration = MarginMomentClock.narratedText(
        charactersPerSecond: ListeningTimeEstimator.defaultCharactersPerSecond
    )

    public var isNarratedText: Bool {
        if case .narratedText = self { return true }
        return false
    }

    /// Progress ticks of a text source advance by a sentence or more, not by half a second, so the largest forward
    /// move that still counts as playback is longer than a media clock's. A long sentence is about 30 s of speech.
    public var tickAdvanceLimitMs: Int {
        isNarratedText ? 45_000 : MarginMomentSequence.maxTickAdvanceMs
    }

    private var charactersPerSecond: Double {
        guard case let .narratedText(rate) = self, rate.isFinite, rate > 0 else {
            return ListeningTimeEstimator.defaultCharactersPerSecond
        }
        return rate
    }

    /// The text offset's place on this clock. Zero for a media clock, which has no text offsets.
    public func position(forTextOffset offset: Int) -> Int {
        guard isNarratedText else { return 0 }
        return Int((Double(max(0, offset)) / charactersPerSecond * 1_000).rounded())
    }

    /// The text offset at a place on this clock. Zero for a media clock.
    public func textOffset(forPosition ms: Int) -> Int {
        guard isNarratedText else { return 0 }
        return Int((Double(max(0, ms)) / 1_000 * charactersPerSecond).rounded())
    }

    /// Where the lead-in should start reading: the first sentence start at or after `offset`, so speech doesn't
    /// begin mid-sentence. `offset` stays as it is when that start would reach `limit` (the Margin itself) or
    /// the text has none after it.
    public static func sentenceStart(atOrAfter offset: Int, before limit: Int, in text: String) -> Int {
        guard offset > 0 else { return 0 }
        let characters = Array(text)
        for index in characters.indices where ".!?".contains(characters[index]) {
            var start = index + 1
            while start < characters.count, characters[start].isWhitespace { start += 1 }
            // A full stop with no space after it (3.5, a.m.) is not the end of a sentence.
            guard start > index + 1, start < characters.count, start >= offset else { continue }
            return start < limit ? start : offset
        }
        return offset
    }
}

/// Which spoken Margins a "Play this moment" plays, and where each sits on the moment's clock (#1577).
public enum MarginMomentPlanner {
    public struct Anchors: Sendable, Equatable {
        public let target: MarginMomentAnchor
        public let others: [MarginMomentAnchor]
    }

    /// - Parameters:
    ///   - played: the Margin the listener chose.
    ///   - spoken: the item's spoken Margins, from every session (it may include `played`).
    ///   - targetMediaTimeMs: on a media clock, where the source stands once the chosen Margin's place is open. It
    ///     places the chosen Margin when it has only a text place (an article's prepared narration or its publisher's
    ///     recording found it, #1537). The item's other Margins need a media time of their own to play inline.
    /// - Returns: nil when the chosen Margin can't be placed on the clock.
    public static func anchors(
        played: Interjection,
        among spoken: [Interjection],
        clock: MarginMomentClock,
        targetMediaTimeMs: Int?
    ) -> Anchors? {
        guard played.isSpokenItemMargin else { return nil }
        func place(_ margin: Interjection) -> Int? {
            if clock.isNarratedText { return clock.position(forTextOffset: margin.anchor.startChar) }
            return margin.anchor.mediaTimeMs
        }
        guard let targetMs = clock.isNarratedText ? place(played) : (played.anchor.mediaTimeMs ?? targetMediaTimeMs) else {
            return nil
        }
        let target = MarginMomentAnchor(marginId: identity(played), mediaTimeMs: targetMs)
        let others = spoken
            .filter { $0.isSpokenItemMargin && identity($0) != target.marginId }
            .compactMap { margin in place(margin).map { MarginMomentAnchor(marginId: identity(margin), mediaTimeMs: $0) } }
        return Anchors(target: target, others: others)
    }

    /// A Margin's identity across sessions: the same id can appear in two sessions of one item. The app's
    /// `Gate1AppModel.marginIdentity` and `MarginRow.id` spell it the same way (`MarginCollectionTests` pins them).
    public static func identity(_ margin: Interjection) -> String {
        "\(margin.sessionId)::\(margin.id)"
    }
}
