import Foundation

/// Notices when playback is meant to be running but the player's clock has stopped moving (#166).
///
/// On a streamed episode the app's clock once stayed at 5:46 for 2.5 minutes while it showed "playing", and the
/// next resume reported 9:33. The playback log couldn't say whether audio stalled or only the clock did. This
/// reports the start and end of each stall so the log can carry the player's own state at that moment.
public struct PlaybackStallDetector: Sendable {
    public enum Event: Sendable, Equatable {
        /// No clock progress for at least `threshold` while playing. Reported once per stall.
        case stalled(atMediaTimeMs: Int, forMs: Int)
        /// The clock moved again, or playback stopped being intended.
        case ended(fromMediaTimeMs: Int, toMediaTimeMs: Int?, stalledForMs: Int)
    }

    public let thresholdMs: Int
    /// Clock movement smaller than this counts as no progress.
    public let minimumProgressMs: Int
    private var lastProgressMediaTimeMs: Int?
    private var lastProgressUptimeMs: Int?
    private var stalledAt: (mediaTimeMs: Int, sinceUptimeMs: Int)?

    public init(thresholdMs: Int = 5_000, minimumProgressMs: Int = 300) {
        self.thresholdMs = thresholdMs
        self.minimumProgressMs = minimumProgressMs
    }

    /// Call periodically with the player's own clock. `intendsToPlay` is the user's intent, not AVPlayer's status.
    public mutating func observe(uptimeMs: Int, mediaTimeMs: Int?, intendsToPlay: Bool) -> Event? {
        guard intendsToPlay, let mediaTimeMs else {
            defer { reset() }
            guard let stalledAt, let since = lastProgressUptimeMs else { return nil }
            return .ended(fromMediaTimeMs: stalledAt.mediaTimeMs, toMediaTimeMs: mediaTimeMs, stalledForMs: uptimeMs - since)
        }
        guard let last = lastProgressMediaTimeMs, let since = lastProgressUptimeMs else {
            lastProgressMediaTimeMs = mediaTimeMs
            lastProgressUptimeMs = uptimeMs
            return nil
        }
        if abs(mediaTimeMs - last) >= minimumProgressMs {
            let ended = stalledAt.map {
                Event.ended(fromMediaTimeMs: $0.mediaTimeMs, toMediaTimeMs: mediaTimeMs, stalledForMs: uptimeMs - since)
            }
            lastProgressMediaTimeMs = mediaTimeMs
            lastProgressUptimeMs = uptimeMs
            stalledAt = nil
            return ended
        }
        guard stalledAt == nil, uptimeMs - since >= thresholdMs else { return nil }
        stalledAt = (last, since)
        return .stalled(atMediaTimeMs: last, forMs: uptimeMs - since)
    }

    public mutating func reset() {
        lastProgressMediaTimeMs = nil
        lastProgressUptimeMs = nil
        stalledAt = nil
    }
}
