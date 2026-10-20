import Foundation

/// Decides when the player's clock has stopped describing the audio, and what to trust instead (#2094).
///
/// On a podcast at 1.5×, AVPlayer's clock stopped moving for 66 s and 137 s after a Margin's rejoin seek while
/// the audio played on. The next Margin was anchored at the frozen time, so its rejoin sent the listener back
/// over everything heard during the freeze. The decoded-audio tap kept seeing the real media time throughout:
/// its buffers carry the source time range AVPlayer is rendering. When the clock (or a pending seek's target)
/// sits still while decoding moves well past it, the decoded time, less the usual decode lead, is the better
/// account of where the listener is.
///
/// Pure value type so the decision is host-testable; the stream client feeds it readings.
public struct DecodedAudioClockGuard: Sendable {
    /// The latest buffer the tap decoded: the media time its audio ends at, and when (system uptime) it ran.
    public struct DecodedSample: Sendable, Equatable {
        public var endMediaTimeMs: Int
        public var uptimeMs: Int

        public init(endMediaTimeMs: Int, uptimeMs: Int) {
            self.endMediaTimeMs = endMediaTimeMs
            self.uptimeMs = uptimeMs
        }
    }

    /// A decoded buffer older than this no longer says audio is playing (paused, buffering, or after a seek).
    public static let freshnessMs = 1_500
    /// The raw clock must sit still at least this long, while playback is intended, before decoding overrules it.
    public static let frozenAfterMs = 1_000
    /// How far past the clock, beyond the usual lead, decoding must be before it is trusted over the clock.
    public static let disagreementToleranceMs = 1_500
    /// A learned lead outside this range is noise, not the decoder running ahead.
    static let maximumLeadMs = 3_000
    /// Decoding runs about half a second ahead of the clock (#1133) until a reading says otherwise.
    public static let defaultLeadMs = 500

    /// How far the tap's decoded audio usually runs ahead of the player's clock, learned while the clock moves.
    public private(set) var decodeLeadMs = Self.defaultLeadMs
    private var rawProgress: (mediaTimeMs: Int, uptimeMs: Int)?
    /// Decoded buffers from before this uptime belong to audio from before the latest seek.
    private var seekUptimeMs: Int?

    public init() {}

    /// System uptime in milliseconds, on the clock both the audio thread and the main thread read.
    public static func uptimeMs() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// A seek began: decoded audio from before it says nothing about where the player is now.
    public mutating func noteSeek(uptimeMs: Int) {
        seekUptimeMs = uptimeMs
        rawProgress = nil
    }

    /// Playback stopped being intended: a clock standing still is expected from here on.
    public mutating func notePaused() {
        rawProgress = nil
    }

    /// Feeds one reading of the player's raw clock while playback is intended, and returns the media time to
    /// trust instead of `reportedMediaTimeMs` (the raw clock, or a pending seek's target), or nil when the
    /// reported time stands. Also learns the decode lead from readings where the clock is moving.
    public mutating func observe(
        reportedMediaTimeMs: Int,
        rawClockMediaTimeMs: Int?,
        decoded: DecodedSample?,
        uptimeMs: Int
    ) -> Int? {
        let fresh = decoded.flatMap { sample -> DecodedSample? in
            guard uptimeMs - sample.uptimeMs <= Self.freshnessMs else { return nil }
            if let seekUptimeMs, sample.uptimeMs < seekUptimeMs { return nil }
            return sample
        }
        var clockFrozen = false
        if let raw = rawClockMediaTimeMs {
            if let progress = rawProgress, progress.mediaTimeMs == raw {
                clockFrozen = uptimeMs - progress.uptimeMs >= Self.frozenAfterMs
            } else {
                if let progress = rawProgress, let fresh, raw > progress.mediaTimeMs {
                    learnLead(fresh.endMediaTimeMs - raw)
                }
                rawProgress = (raw, uptimeMs)
            }
        }
        guard clockFrozen, let fresh else { return nil }
        let trusted = fresh.endMediaTimeMs - decodeLeadMs
        guard trusted - reportedMediaTimeMs > Self.disagreementToleranceMs else { return nil }
        return trusted
    }

    private mutating func learnLead(_ sample: Int) {
        guard sample >= 0, sample <= Self.maximumLeadMs else { return }
        decodeLeadMs = (decodeLeadMs * 3 + sample) / 4
    }
}
