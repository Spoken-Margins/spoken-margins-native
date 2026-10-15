import Foundation

/// What the narration player does at the seam between two chunks while the app is away (#538).
///
/// Supertonic plays each rendered chunk as its own item. When a chunk ends, nothing is playing until the app
/// makes the next player and starts it, and a backgrounded app that has nothing playing can be suspended in that
/// moment (the owner's 2026-10-07 export: a ready item at time 0, rate 0, and a watchdog that only ran when he came
/// back). A background-time hold narrows the gap but still needs the app to run. Putting the next rendered chunk on
/// the player before the current one ends lets the system start it with no app code at all.
///
/// The decision lives here, away from AVFoundation, so a table covers it. A chunk that needs the app at its start
/// (the voice-change chime, the bundled-voice notice) is never queued, and neither is anything while the app is in
/// front: the seam there is unchanged.
public enum BackgroundChunkSeam {
    /// What is known about the chunk after the playing one.
    public struct Facts: Equatable, Sendable {
        public var appIsActive: Bool
        public var intendsToPlay: Bool
        public var nextChunkExists: Bool
        public var nextChunkIsRendered: Bool
        /// A chunk read by another voice (the iOS voice or the bundled one): its start has a chime or a notice.
        public var nextChunkIsStandIn: Bool
        public var alreadyQueued: Bool

        public init(
            appIsActive: Bool,
            intendsToPlay: Bool,
            nextChunkExists: Bool,
            nextChunkIsRendered: Bool,
            nextChunkIsStandIn: Bool,
            alreadyQueued: Bool
        ) {
            self.appIsActive = appIsActive
            self.intendsToPlay = intendsToPlay
            self.nextChunkExists = nextChunkExists
            self.nextChunkIsRendered = nextChunkIsRendered
            self.nextChunkIsStandIn = nextChunkIsStandIn
            self.alreadyQueued = alreadyQueued
        }
    }

    /// True when the next chunk should go onto the player now.
    public static func shouldQueueAhead(_ facts: Facts) -> Bool {
        !facts.appIsActive
            && facts.intendsToPlay
            && facts.nextChunkExists
            && facts.nextChunkIsRendered
            && !facts.nextChunkIsStandIn
            && !facts.alreadyQueued
    }

    /// How a seam went while the app was away, for the export.
    public enum Outcome: String, CaseIterable, Sendable {
        /// The next chunk was already on the player and started without the app.
        case queuedAhead = "queued_ahead"
        /// The next chunk had not finished rendering when the seam came.
        case nextNotRendered = "next_not_rendered"
        /// The next chunk is read by another voice, which needs the app at its start.
        case standInVoice = "stand_in_voice"
        /// The next chunk was rendered but was not on the player in time.
        case renderedNotQueued = "rendered_not_queued"
    }

    /// Why a seam that came with the app away was not a queued one.
    public static func missedOutcome(nextChunkIsRendered: Bool, nextChunkIsStandIn: Bool) -> Outcome {
        if nextChunkIsStandIn { return .standInVoice }
        return nextChunkIsRendered ? .renderedNotQueued : .nextNotRendered
    }
}

/// Counts the seams that came while the app was away, by how they went (#538), so one line of an export says
/// whether the owner's phone got through them without the app.
public struct BackgroundSeamLog: Equatable, Sendable {
    private var counts: [BackgroundChunkSeam.Outcome: Int] = [:]

    public init() {}

    public var total: Int { counts.values.reduce(0, +) }

    public func count(_ outcome: BackgroundChunkSeam.Outcome) -> Int { counts[outcome, default: 0] }

    /// Adds one seam. True the first time this outcome is seen, which is when it is worth a line in the event log.
    @discardableResult
    public mutating func record(_ outcome: BackgroundChunkSeam.Outcome) -> Bool {
        counts[outcome, default: 0] += 1
        return counts[outcome] == 1
    }

    /// `queued_ahead 12, next_not_rendered 2`, in a fixed order; nil before any seam.
    public var summary: String? {
        let parts = BackgroundChunkSeam.Outcome.allCases.compactMap { outcome in
            counts[outcome].map { "\(outcome.rawValue) \($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
