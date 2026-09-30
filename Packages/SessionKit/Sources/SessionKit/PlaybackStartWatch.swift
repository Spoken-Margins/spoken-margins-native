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
        var startedAt: Date
        var cued = false
    }

    public let cueDelay: TimeInterval
    private var start: Start?
    private var last: (itemId: String?, status: PlaybackStatus)?

    public init(cueDelay: TimeInterval = 0.8) {
        self.cueDelay = cueDelay
    }

    /// The item whose start is still silent, if any.
    public var waitingItemId: String? { start?.itemId }

    /// Feed every snapshot change. Returns the outcome when a start resolves. A start opens when playback goes to
    /// "starting" from a stop (idle, paused, failed, recording) or on another item. A skip, seek or rate change
    /// while playing also passes through "starting", and is not a new start.
    public mutating func observe(itemId: String?, status: PlaybackStatus, at now: Date) -> Outcome? {
        let previous = last
        last = (itemId, status)
        var outcome: Outcome?
        if let start {
            if status == .starting, itemId == start.itemId { return nil }
            let milliseconds = max(0, Int((now.timeIntervalSince(start.startedAt) * 1000).rounded()))
            outcome = status == .playing && itemId == start.itemId
                ? .firstAudio(itemId: start.itemId, milliseconds: milliseconds)
                : .ended(itemId: start.itemId, milliseconds: milliseconds, status: status)
            self.start = nil
        }
        let continuesPlayback = previous.map { $0.status.isPlaybackActive && $0.itemId == itemId } ?? false
        if status == .starting, let itemId, !continuesPlayback {
            start = Start(itemId: itemId, startedAt: now)
        }
        return outcome
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
