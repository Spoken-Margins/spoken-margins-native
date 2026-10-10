import Foundation

/// What the screen may say about a shared Margin's voice (#941).
public enum SharedMarginPlaybackPhase: Equatable, Sendable {
    /// Playback was asked for, or the clock has stopped for a moment. Words: "Loading Margin…".
    case loading
    /// The voice clock is advancing. Words: "Playing".
    case playing
    /// The listener paused it.
    case paused
    /// The voice cannot play. Words: "Margin audio could not play", with Retry.
    case failed(SharedMarginPlaybackFailure)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the transport shows Pause (the voice is, or should soon be, sounding) rather than Play.
    public var showsPause: Bool {
        switch self {
        case .loading, .playing: return true
        case .paused, .failed: return false
        }
    }
}

public enum SharedMarginPlaybackFailure: Equatable, Sendable {
    /// The player or its item reported a failure (an unreadable or damaged voice file).
    case unreadable
    /// The player asked to play but its clock never advanced, or stopped for good.
    case noProgress
}

/// Judges one attempt to play a shared Margin's voice from what the player reports, so the
/// card, the transport icon and Now Playing say what is true. A requested rate or an existing
/// file proves nothing: a damaged file accepts `play` and then reports a failed item with a
/// clock stuck at zero. "Playing" is earned only by a clock that advances.
///
/// One value per attempt. Listen and Retry each start a new one, so a late reading from an
/// earlier attempt never reaches a later one (the model compares `attemptID`). Time is passed
/// in (a monotonic clock) so the rule is host-testable without waiting.
public struct SharedMarginPlaybackHealth: Equatable, Sendable {
    public struct Limits: Equatable, Sendable {
        /// A clock that has not moved this long after the voice was asked to play (or resumed) is not going to.
        public var firstSoundTimeout: TimeInterval
        /// An advancing clock that then stays still this long is called "loading", not "playing".
        public var stallNotice: TimeInterval
        /// An advancing clock that then stays still this long has stopped for good.
        public var stallTimeout: TimeInterval
        /// The least change in seconds that counts as the clock advancing.
        public var advanceThreshold: Double

        public static let standard = Limits(firstSoundTimeout: 10, stallNotice: 1.5, stallTimeout: 15, advanceThreshold: 0.01)

        public init(firstSoundTimeout: TimeInterval, stallNotice: TimeInterval, stallTimeout: TimeInterval, advanceThreshold: Double) {
            self.firstSoundTimeout = firstSoundTimeout
            self.stallNotice = stallNotice
            self.stallTimeout = stallTimeout
            self.advanceThreshold = advanceThreshold
        }
    }

    public let attemptID: UUID
    public let limits: Limits
    public private(set) var phase: SharedMarginPlaybackPhase = .loading
    /// Whether the clock has advanced at least once in this attempt.
    public private(set) var hasPlayed = false
    public private(set) var isUserPaused = false
    private var highWaterSeconds = 0.0
    private var lastProgressAt: TimeInterval

    public init(attemptID: UUID = UUID(), startedAt: TimeInterval, limits: Limits = .standard) {
        self.attemptID = attemptID
        self.limits = limits
        self.lastProgressAt = startedAt
    }

    /// The listener paused or resumed. Time spent paused never counts against the voice, and a
    /// resume starts the stall clock afresh. A failed attempt stays failed: resuming it is a Retry.
    public mutating func setUserPaused(_ paused: Bool, at now: TimeInterval) {
        guard !phase.isFailed, paused != isUserPaused else { return }
        isUserPaused = paused
        if paused {
            phase = .paused
        } else {
            lastProgressAt = now
            phase = hasPlayed ? .playing : .loading
        }
    }

    /// Feeds one reading of the player and returns the phase to show.
    /// - Parameters:
    ///   - playerFailed: the item's or the player's status is `.failed`.
    ///   - clockSeconds: the item's current time; `nil`, NaN, infinite or negative means "no reading".
    @discardableResult
    public mutating func observe(playerFailed: Bool, clockSeconds: Double?, at now: TimeInterval) -> SharedMarginPlaybackPhase {
        if phase.isFailed { return phase }
        if playerFailed {
            phase = .failed(.unreadable)
            return phase
        }
        if let clock = clockSeconds, clock.isFinite, clock > highWaterSeconds + limits.advanceThreshold {
            highWaterSeconds = clock
            lastProgressAt = now
            hasPlayed = true
        }
        if isUserPaused {
            phase = .paused
            return phase
        }
        let stillFor = max(0, now - lastProgressAt)
        if stillFor >= (hasPlayed ? limits.stallTimeout : limits.firstSoundTimeout) {
            phase = .failed(.noProgress)
        } else if !hasPlayed || stillFor >= limits.stallNotice {
            phase = .loading
        } else {
            phase = .playing
        }
        return phase
    }

    public var showsPause: Bool { phase.showsPause }

    /// The rate Now Playing may report: only a confirmed advancing clock claims to be playing,
    /// whatever rate the player says it was asked for.
    public func nowPlayingRate(playerRate: Double) -> Double {
        phase == .playing ? playerRate : 0
    }
}
