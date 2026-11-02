import Foundation

/// Remembers where our own player was, and when, so a Margin taken a moment ago with no live session (from the Watch
/// or the Lock Screen) can be put on the item that was playing, at the time it was taken (#2542;
/// `docs/design/live-sessions/DESIGN.md` section 2 point 12).
///
/// The app feeds it what the player reports (`observe`), and `LiveSessionFiling` reads the result as `PlayerRun`s: a
/// stretch of steady playback of one item, from a start position at one rate. A run ends when playback stops, the item
/// changes, the rate changes, or the position jumps away from where steady playback would have put it (a seek, a skip,
/// a stall). So a Margin is placed only inside time we can vouch for, and one that falls in a gap is filed by the rest
/// of the rule (a quick session), never at a guessed place.
///
/// Memory only, and bounded: runs older than `keepFor` or past `capacity` are dropped. Pure, with no clock of its own.
public struct PlayerRunRecorder: Equatable, Sendable {
    /// What the player reports at one moment.
    public struct Observation: Equatable, Sendable {
        public var itemId: String?
        public var mediaTimeMs: Int?
        public var rate: Double
        /// True only while audio is really playing (not paused, starting, recording or finished).
        public var isPlaying: Bool

        public init(itemId: String?, mediaTimeMs: Int?, rate: Double, isPlaying: Bool) {
            self.itemId = itemId
            self.mediaTimeMs = mediaTimeMs
            self.rate = rate
            self.isPlaying = isPlaying
        }
    }

    /// How far the reported position may differ from steady playback before it counts as a jump.
    public static let jumpTolerance: TimeInterval = 1.5
    /// How long a finished run is kept. A Watch Margin arrives within minutes; this is generous.
    public static let keepFor: TimeInterval = 6 * 60 * 60
    public static let capacity = 200

    private struct Open: Equatable, Sendable {
        var itemId: String
        var startedAt: Date
        var startPositionMs: Int
        var rate: Double
        var lastSeenAt: Date
    }

    private var finished: [LiveSessionFiling.PlayerRun] = []
    private var open: Open?

    public init() {}

    /// Notes what the player reports at `time`.
    public mutating func observe(_ observation: Observation, at time: Date) {
        guard observation.isPlaying, let itemId = observation.itemId, let positionMs = observation.mediaTimeMs,
              observation.rate > 0, positionMs >= 0 else {
            closeOpen(at: time)
            drop(before: time)
            return
        }
        if var current = open {
            let expectedMs = current.startPositionMs + Int((time.timeIntervalSince(current.startedAt) * 1_000 * current.rate).rounded())
            let steady = current.itemId == itemId
                && current.rate == observation.rate
                && abs(Double(positionMs - expectedMs)) <= Self.jumpTolerance * 1_000
            if steady {
                current.lastSeenAt = time
                open = current
                drop(before: time)
                return
            }
            // A change of item, rate or place. A rate change is continuous, so its run runs up to now; anything else
            // is vouched for only up to the last time we saw it steady.
            let continuous = current.itemId == itemId && current.rate != observation.rate
                && abs(Double(positionMs - expectedMs)) <= Self.jumpTolerance * 1_000
            closeOpen(at: continuous ? time : current.lastSeenAt)
        }
        open = Open(itemId: itemId, startedAt: time, startPositionMs: positionMs, rate: observation.rate, lastSeenAt: time)
        drop(before: time)
    }

    /// The runs to file against at `now`, oldest first: the finished ones, and the one still going, up to `now`.
    public func runs(at now: Date) -> [LiveSessionFiling.PlayerRun] {
        var all = finished
        if let current = open, now >= current.startedAt {
            all.append(LiveSessionFiling.PlayerRun(
                itemId: current.itemId, startedAt: current.startedAt, endedAt: now,
                startPositionMs: current.startPositionMs, rate: current.rate
            ))
        }
        return all
    }

    private mutating func closeOpen(at end: Date) {
        guard let current = open else { return }
        open = nil
        guard end > current.startedAt else { return }
        finished.append(LiveSessionFiling.PlayerRun(
            itemId: current.itemId, startedAt: current.startedAt, endedAt: end,
            startPositionMs: current.startPositionMs, rate: current.rate
        ))
    }

    private mutating func drop(before now: Date) {
        let oldest = now.addingTimeInterval(-Self.keepFor)
        finished.removeAll { $0.endedAt < oldest }
        if finished.count > Self.capacity { finished.removeFirst(finished.count - Self.capacity) }
    }
}
