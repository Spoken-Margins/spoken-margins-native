import Foundation

/// Times each playback start, from the first "starting" status to confirmed playback (#357). On J1 the first
/// word took about 15 s with only a spinner, and nothing recorded how long starts really take. The watch also says
/// when a start has been silent long enough to deserve an audible cue, once per start.
public struct PlaybackStartWatch: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Audio started this many milliseconds after the start began.
        case firstAudio(itemId: String, milliseconds: Int)
        /// The start ended without audio: it was paused, it failed, or another item started.
        case ended(itemId: String, milliseconds: Int, status: PlaybackStatus)
    }

    private struct Start: Sendable {
        var itemId: String
        var targetId: String?
        var requestedAt: Date?
        var startedAt: Date
        var cued = false
    }

    public let cueDelay: TimeInterval
    private var start: Start?
    private var last: (itemId: String?, targetId: String?, requestedAt: Date?, status: PlaybackStatus)?

    /// Counts the starts opened so far, so a caller can tell a new start from the same one continuing.
    public private(set) var startCount = 0

    public init(cueDelay: TimeInterval = 0.8) {
        self.cueDelay = cueDelay
    }

    /// The item whose start is still silent, if any.
    public var waitingItemId: String? { start?.itemId }

    /// The target (the item's own audio, or a Margin answer or summary on it) of the start that is still silent.
    public var waitingTargetId: String? { start?.targetId }

    /// Feed every snapshot change. Returns what resolved: the open start's outcome, and a start that played at once.
    /// One start is one listener request: `requestedAt` is when it reached the engine (the snapshot's
    /// `playbackRequestedAt`), so the time counts the work before the start was published (audits of #580).
    /// A start opens when playback goes to "starting" from a stop (idle, paused, failed, recording), on another
    /// item, or under a new request while playing (a Margin's answer, or another session of the same article). A
    /// seek, skip or rate change that stays playing needs no cue. One that returns to "starting" has become
    /// silent and opens a wait from that transition, rather than reusing the old request's time (#1101).
    /// The engine switching a waiting start to another target (narration falling back to live speech) keeps its wait. Without request times,
    /// a new target counts as a new start. A start the player confirms at once (a buffered resume) goes straight to
    /// "playing" and is first audio too. A missing or implausible request time falls back to `now`.
    public mutating func observe(
        itemId: String?, targetId: String? = nil, status: PlaybackStatus, requestedAt: Date? = nil, at now: Date
    ) -> [Outcome] {
        let previous = last
        last = (itemId, targetId, requestedAt, status)
        var outcomes: [Outcome] = []
        if let start {
            let sameStart = itemId == start.itemId
                && Self.sameRequest(requestedAt, targetId, as: start.requestedAt, start.targetId)
            if status == .starting, sameStart {
                self.start?.targetId = targetId
                return []
            }
            let milliseconds = Self.milliseconds(from: start.startedAt, to: now)
            outcomes.append(status == .playing && sameStart
                ? .firstAudio(itemId: start.itemId, milliseconds: milliseconds)
                : .ended(itemId: start.itemId, milliseconds: milliseconds, status: status))
            self.start = nil
            if status == .playing, sameStart { return outcomes }
        }
        let continuesPlayback = previous.map {
            $0.status.isPlaybackActive && $0.itemId == itemId
                && Self.sameRequest(requestedAt, targetId, as: $0.requestedAt, $0.targetId)
        } ?? false
        let becameSilent = status == .starting && previous?.status == .playing
        if let itemId, !continuesPlayback || becameSilent {
            let startedAt = continuesPlayback ? now
                : requestedAt.flatMap { (now.addingTimeInterval(-Self.longestRequest)...now).contains($0) ? $0 : nil } ?? now
            if status == .starting {
                start = Start(itemId: itemId, targetId: targetId, requestedAt: requestedAt, startedAt: startedAt)
                startCount += 1
            } else if status == .playing {
                outcomes.append(.firstAudio(itemId: itemId, milliseconds: Self.milliseconds(from: startedAt, to: now)))
            }
        }
        return outcomes
    }

    /// The same request when both carry a request time; otherwise the same target.
    private static func sameRequest(_ requestedAt: Date?, _ targetId: String?, as other: Date?, _ otherTargetId: String?) -> Bool {
        if let requestedAt, let other { return requestedAt == other }
        return targetId == otherTargetId
    }

    /// A request stamp older than this belongs to an earlier command, not this start.
    static let longestRequest: TimeInterval = 120

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    /// How much longer the open start may stay silent before its cue is due, or nil when no start is open. The
    /// delay runs from the listener's request, so work done before the start was published counts (audit of #580).
    public func cueWait(at now: Date) -> TimeInterval? {
        start.map { max(0, cueDelay - now.timeIntervalSince($0.startedAt)) }
    }

    /// True once per start, when it has been silent for `cueDelay`.
    public mutating func takeCue(at now: Date) -> Bool {
        guard var start, !start.cued, now.timeIntervalSince(start.startedAt) >= cueDelay else { return false }
        start.cued = true
        self.start = start
        return true
    }

    /// The words shown in place of a bare spinner while a start is silent.
    public static func waitingText(isMedia: Bool) -> String {
        isMedia ? "Loading audio…" : "Preparing voice…"
    }
}

/// A short, soft two-note chime, built in memory as 16-bit mono WAV so the app ships no sound file (#357).
public enum PlaybackStartChime {
    public static let sampleRate = 22_050
    /// Two rising notes (E5 then A5), each faded in and out so they don't click.
    public static let notes: [(frequency: Double, seconds: Double)] = [(659.25, 0.09), (880.0, 0.12)]
    public static let peak = 0.3

    public static func wavData() -> Data {
        var samples: [Int16] = []
        for note in notes {
            let count = Int(Double(sampleRate) * note.seconds)
            let fade = max(1, count / 5)
            for index in 0..<count {
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                let value = sin(2 * .pi * note.frequency * Double(index) / Double(sampleRate)) * envelope * peak
                samples.append(Int16((value * Double(Int16.max)).rounded()))
            }
        }
        return PlaybackCueWave.wavData(samples: samples, sampleRate: sampleRate)
    }
}

/// 16-bit mono WAV bytes for the cues that are built in memory.
enum PlaybackCueWave {
    static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload))
        samples.forEach(append)
        return data
    }
}
