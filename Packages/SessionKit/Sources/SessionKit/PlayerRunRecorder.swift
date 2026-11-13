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
        /// True while an item is loaded and paused (not recording, starting or failed, and not finished: a natural end is not a pause). The item then stays the
        /// one a Watch Margin belongs on, at the place it was paused (#4079).
        public var isPaused: Bool

        public init(itemId: String?, mediaTimeMs: Int?, rate: Double, isPlaying: Bool, isPaused: Bool = false) {
            self.itemId = itemId
            self.mediaTimeMs = mediaTimeMs
            self.rate = rate
            self.isPlaying = isPlaying
            self.isPaused = isPaused
        }
    }

    /// What the player's snapshot says. A finished item reads as paused in the snapshot (the engine stops at a natural
    /// end), but it is not one: nothing is waiting to be resumed there (#4079).
    public static func observation(of snapshot: SessionSnapshot) -> Observation {
        Observation(
            itemId: snapshot.itemId, mediaTimeMs: snapshot.currentMediaTimeMs, rate: snapshot.playbackRate,
            isPlaying: snapshot.status == .playing, isPaused: snapshot.status == .paused && snapshot.phase != .finished
        )
    }

    /// How far the reported position may differ from steady playback before it counts as a jump.
    public static let jumpTolerance: TimeInterval = 1.5
    /// How long a finished run is kept. A Watch Margin arrives within minutes; this is generous.
    public static let keepFor: TimeInterval = 6 * 60 * 60
    public static let capacity = 200
    /// How long after a pause the item still holds a Margin: a Watch recording pauses the phone, and its Margin arrives
    /// within seconds to minutes. Past this, filing falls back to the rest of the rule, so a Margin taken much later
    /// never lands on an item left paused (#4079).
    public static let parkedHold: TimeInterval = 10 * 60

    private struct Open: Equatable, Sendable {
        var itemId: String
        var startedAt: Date
        var startPositionMs: Int
        var rate: Double
        var lastSeenAt: Date
    }

    private var finished: [LiveSessionFiling.PlayerRun] = []
    private var open: Open?
    /// An item loaded and paused: a stretch at rate 0, so a Margin taken while it waits files at its place (#4079).
    private var parked: Open?

    public init() {}

    /// Notes what the player reports at `time`.
    public mutating func observe(_ observation: Observation, at time: Date) {
        observeParked(observation, at: time)
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
        if let current = parked, now >= current.startedAt {
            all.append(LiveSessionFiling.PlayerRun(
                itemId: current.itemId, startedAt: current.startedAt,
                endedAt: min(now, current.startedAt.addingTimeInterval(Self.parkedHold)),
                startPositionMs: current.startPositionMs, rate: 0
            ))
        }
        return all
    }

    /// Tracks the item the listener just paused. Only an item that was playing in this process parks, started where that
    /// play run ended (a pause arriving with no play run before it, like the last session restored at launch, parks
    /// nothing). It holds for `parkedHold` after the pause and no longer. It ends when playing resumes, and a seek or
    /// another item while paused ends it up to the last sighting; each of those snapshots arrives here, and a paused
    /// item does not park again without playing first, so the Margin goes to what is on screen or is filed as before.
    private mutating func observeParked(_ observation: Observation, at time: Date) {
        if let current = parked {
            let near = observation.mediaTimeMs.map { abs(Double($0 - current.startPositionMs)) <= Self.jumpTolerance * 1_000 } == true
            if observation.isPaused, observation.itemId == current.itemId, near {
                parked?.lastSeenAt = time
                return
            }
            let resumedHere = observation.itemId == current.itemId && observation.isPlaying && near
            closeParked(at: resumedHere ? time : current.lastSeenAt)
        }
        guard observation.isPaused, let itemId = observation.itemId, let positionMs = observation.mediaTimeMs, positionMs >= 0,
              let last = open, last.itemId == itemId else { return }
        parked = Open(itemId: itemId, startedAt: last.lastSeenAt, startPositionMs: positionMs, rate: 0, lastSeenAt: time)
    }

    private mutating func closeParked(at end: Date) {
        guard let current = parked else { return }
        parked = nil
        let end = min(end, current.startedAt.addingTimeInterval(Self.parkedHold))
        guard end > current.startedAt else { return }
        finished.append(LiveSessionFiling.PlayerRun(
            itemId: current.itemId, startedAt: current.startedAt, endedAt: end,
            startPositionMs: current.startPositionMs, rate: 0
        ))
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
