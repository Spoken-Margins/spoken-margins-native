import Foundation
import SessionKit

/// A stretch of episode audio the listener actually heard around one Margin, as mono speech-rate samples (#156).
///
/// Built from the player's own decoded audio, so it matches the edition (and ads) the listener heard and needs no
/// network. Segments are contiguous runs; a seek starts a new one.
public struct HeardAudioWindow: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let startMediaTimeMs: Int
        public let samples: [Float]

        public init(startMediaTimeMs: Int, samples: [Float]) {
            self.startMediaTimeMs = startMediaTimeMs
            self.samples = samples
        }
    }

    public let request: PostResumeAudioSampleRequest
    public let sampleRate: Double
    public let segments: [Segment]
    /// Why collection stopped: "complete", "seeked", "stopped".
    public let endReason: String

    public init(request: PostResumeAudioSampleRequest, sampleRate: Double, segments: [Segment], endReason: String) {
        self.request = request
        self.sampleRate = sampleRate
        self.segments = segments
        self.endReason = endReason
    }

    public func durationMs(of segment: Segment) -> Int {
        Int((Double(segment.samples.count) / sampleRate * 1_000).rounded())
    }

    public var coversBeforeAnchor: Bool {
        segments.contains { $0.startMediaTimeMs < request.anchorMediaTimeMs - 1_000 }
    }

    public var coversAfterAnchor: Bool {
        segments.contains { $0.startMediaTimeMs + durationMs(of: $0) > request.anchorMediaTimeMs + 1_000 }
    }

    /// Joins per-segment transcripts (each timed from its own start) into one timeline in episode time.
    public static func episodeTimeline(_ parts: [(startMediaTimeMs: Int, timeline: MediaTimeline)]) -> MediaTimeline {
        var segments: [MediaTimelineSegment] = []
        for (index, part) in parts.enumerated() {
            for segment in part.timeline.segments {
                segments.append(MediaTimelineSegment(
                    id: "heard-\(index)-\(segment.id)",
                    startMs: segment.startMs + part.startMediaTimeMs,
                    endMs: segment.endMs + part.startMediaTimeMs,
                    text: segment.text,
                    sourceLocator: segment.sourceLocator
                ))
            }
        }
        return MediaTimeline(segments: segments.sorted { $0.startMs < $1.startMs }, chapters: [])
    }
}

/// Keeps the last minute of heard audio and, for each Margin, collects up to a minute after playback resumes (#156).
///
/// Runs on the tap's worker queue (#457) under the tap's lock, so it only copies samples: no allocation-heavy work
/// beyond appending, no I/O. The caller downsamples to mono speech rate before appending.
public struct HeardAudioWindowRecorder: Sendable {
    public static let beforeMs = 60_000
    public static let afterMs = 60_000
    /// Chunks further apart than this aren't one contiguous run (a seek or a dropped buffer).
    static let contiguityToleranceMs = 250
    /// Rounding slack when deciding whether a chunk only replays audio a window already holds.
    static let replayToleranceMs = 10

    private struct Chunk: Sendable {
        let startMediaTimeMs: Int
        let samples: [Float]
    }

    private struct Collecting: Sendable {
        let request: PostResumeAudioSampleRequest
        let before: [Chunk]
        var after: [Chunk] = []
        var afterSampleCount = 0
        /// The end of the audio this window already holds. A Margin rejoins a few seconds before its anchor
        /// (#776), so the first seconds after resuming replay the end of `before`; they aren't collected twice.
        var heardUntilMs: Int
    }

    public let sampleRate: Double
    private var ring: [Chunk] = []
    private var ringSampleCount = 0
    private var collecting: [String: Collecting] = [:]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    private var beforeCapacity: Int { Int(sampleRate * Double(Self.beforeMs) / 1_000) }
    private var afterCapacity: Int { Int(sampleRate * Double(Self.afterMs) / 1_000) }

    public var isCollecting: Bool { !collecting.isEmpty }

    /// Appends heard samples. Returns windows that just reached a full minute after resuming.
    public mutating func append(samples: [Float], startMediaTimeMs: Int) -> [HeardAudioWindow] {
        guard !samples.isEmpty else { return [] }
        let chunk = Chunk(startMediaTimeMs: startMediaTimeMs, samples: samples)
        // Playback moved back without a seek being noted (a Margin's rejoin step-back, #776): the audio from
        // here on is about to play again, so the rolling minute drops its first copy of it, cutting a chunk the
        // rewind lands inside.
        if let last = ring.last, startMediaTimeMs + Self.replayToleranceMs < endMs(of: last) {
            ring = ring.compactMap { trimmed($0, before: startMediaTimeMs) }
            ringSampleCount = ring.reduce(0) { $0 + $1.samples.count }
        }
        ring.append(chunk)
        ringSampleCount += samples.count
        while let first = ring.first, ringSampleCount - first.samples.count >= beforeCapacity {
            ring.removeFirst()
            ringSampleCount -= first.samples.count
        }
        let chunkEndMs = endMs(of: chunk)
        var finished: [HeardAudioWindow] = []
        for key in Array(collecting.keys) {
            guard var window = collecting[key],
                  let fresh = unheard(chunk, after: window.heardUntilMs) else { continue }
            window.heardUntilMs = max(window.heardUntilMs, chunkEndMs)
            window.after.append(fresh)
            window.afterSampleCount += fresh.samples.count
            if window.afterSampleCount >= afterCapacity {
                finished.append(makeWindow(window, endReason: "complete"))
                collecting[key] = nil
            } else {
                collecting[key] = window
            }
        }
        return finished
    }

    /// Called when a Margin finishes, before playback resumes: snapshots the minute before its anchor and starts
    /// collecting what plays next. The snapshot keeps the whole rolling minute, including the half second or so
    /// the player decoded past the anchor before it paused: the rejoin replays that audio, and leaving it out
    /// left a hole right after the Margin (#1133).
    public mutating func begin(_ request: PostResumeAudioSampleRequest) {
        let key = Self.key(request)
        let before = ring
        collecting[key] = Collecting(
            request: request,
            before: before,
            heardUntilMs: before.map(endMs(of:)).max() ?? Int.min
        )
    }

    /// The last `lastMs` of heard audio up to `endingAtMs`, from the newest unbroken run of the rolling minute: what
    /// was said just before a Margin's tap, for the recording screen's "Just heard" card on a podcast (#2966). The
    /// tap decodes a little ahead of the clock, so audio past `endingAtMs` is left out. Nil when the run holds less
    /// than `minimumMs` before that point: just after a seek, or before the tap has heard anything.
    public func recentRun(endingAtMs: Int, lastMs: Int, minimumMs: Int = 2_000) -> HeardAudioWindow.Segment? {
        var newestFirst: [Chunk] = []
        for chunk in ring.reversed() {
            if let later = newestFirst.last,
               abs(endMs(of: chunk) - later.startMediaTimeMs) > Self.contiguityToleranceMs { break }
            newestFirst.append(chunk)
        }
        let run = Array(newestFirst.reversed())
        guard let first = run.first, let last = run.last else { return nil }
        let endMs = min(endingAtMs, self.endMs(of: last))
        let startMs = max(first.startMediaTimeMs, endMs - lastMs)
        guard endMs - startMs >= minimumMs else { return nil }
        var samples: [Float] = []
        var segmentStartMs: Int?
        for chunk in run {
            let chunkEndMs = self.endMs(of: chunk)
            guard chunkEndMs > startMs, chunk.startMediaTimeMs < endMs else { continue }
            let from = max(0, Int((Double(startMs - chunk.startMediaTimeMs) * sampleRate / 1_000).rounded()))
            let to = min(chunk.samples.count, Int((Double(endMs - chunk.startMediaTimeMs) * sampleRate / 1_000).rounded()))
            guard from < to else { continue }
            if segmentStartMs == nil {
                segmentStartMs = chunk.startMediaTimeMs + Int((Double(from) / sampleRate * 1_000).rounded())
            }
            samples.append(contentsOf: chunk.samples[from..<to])
        }
        guard let segmentStartMs, !samples.isEmpty else { return nil }
        return HeardAudioWindow.Segment(startMediaTimeMs: segmentStartMs, samples: samples)
    }

    /// A seek ends every window in progress with what it has, and empties the rolling minute.
    public mutating func noteSeek() -> [HeardAudioWindow] {
        ring.removeAll()
        ringSampleCount = 0
        return finishAll(reason: "seeked")
    }

    public mutating func finishAll(reason: String) -> [HeardAudioWindow] {
        let windows = collecting.values.map { makeWindow($0, endReason: reason) }
        collecting.removeAll()
        return windows
    }

    /// The part of `chunk` from `heardUntilMs` on, or nil when the window already holds all of it. A chunk
    /// that starts within rounding of the held audio's end is kept whole.
    private func unheard(_ chunk: Chunk, after heardUntilMs: Int) -> Chunk? {
        if heardUntilMs <= chunk.startMediaTimeMs + Self.replayToleranceMs { return chunk }
        guard endMs(of: chunk) > heardUntilMs + Self.replayToleranceMs else { return nil }
        let dropped = Int((Double(heardUntilMs - chunk.startMediaTimeMs) * sampleRate / 1_000).rounded())
        guard dropped < chunk.samples.count else { return nil }
        return Chunk(startMediaTimeMs: heardUntilMs, samples: Array(chunk.samples[dropped...]))
    }

    /// The part of `chunk` before `rewindMs`, or nil when none of it is.
    private func trimmed(_ chunk: Chunk, before rewindMs: Int) -> Chunk? {
        guard chunk.startMediaTimeMs < rewindMs else { return nil }
        guard endMs(of: chunk) > rewindMs else { return chunk }
        let kept = Int((Double(rewindMs - chunk.startMediaTimeMs) * sampleRate / 1_000).rounded())
        guard kept > 0 else { return nil }
        return Chunk(startMediaTimeMs: chunk.startMediaTimeMs, samples: Array(chunk.samples.prefix(kept)))
    }

    private func endMs(of chunk: Chunk) -> Int {
        chunk.startMediaTimeMs + Int((Double(chunk.samples.count) / sampleRate * 1_000).rounded())
    }

    public static func key(_ request: PostResumeAudioSampleRequest) -> String {
        "\(request.sessionId)::\(request.interjectionId)"
    }

    private func makeWindow(_ window: Collecting, endReason: String) -> HeardAudioWindow {
        var segments: [HeardAudioWindow.Segment] = []
        var runStart: Int?
        var runSamples: [Float] = []
        var expectedNextMs: Int?
        for chunk in window.before + window.after {
            if let expected = expectedNextMs, abs(chunk.startMediaTimeMs - expected) <= Self.contiguityToleranceMs,
               runStart != nil {
                runSamples.append(contentsOf: chunk.samples)
            } else {
                if let start = runStart, !runSamples.isEmpty {
                    segments.append(.init(startMediaTimeMs: start, samples: runSamples))
                }
                runStart = chunk.startMediaTimeMs
                runSamples = chunk.samples
            }
            expectedNextMs = chunk.startMediaTimeMs + Int((Double(chunk.samples.count) / sampleRate * 1_000).rounded())
        }
        if let start = runStart, !runSamples.isEmpty {
            segments.append(.init(startMediaTimeMs: start, samples: runSamples))
        }
        return HeardAudioWindow(request: window.request, sampleRate: sampleRate, segments: segments, endReason: endReason)
    }
}

/// Mixes a decoded float buffer to mono and decimates it to about 16-24 kHz for speech recognition.
public enum HeardAudioDownsampler {
    public static func factor(for sampleRate: Double) -> Int {
        max(1, Int(sampleRate / 16_000))
    }

    /// `channels` are per-channel sample pointers (deinterleaved) or one interleaved pointer with `stride` channels.
    public static func mono(
        channels: [UnsafePointer<Float>],
        interleavedStride: Int,
        frameCount: Int,
        factor: Int
    ) -> [Float] {
        guard frameCount >= factor, !channels.isEmpty, factor > 0 else { return [] }
        let outputCount = frameCount / factor
        var output = [Float](repeating: 0, count: outputCount)
        let channelCount = interleavedStride > 1 ? interleavedStride : channels.count
        let scale = 1 / Float(factor * channelCount)
        for index in 0..<outputCount {
            var sum: Float = 0
            for offset in 0..<factor {
                let frame = index * factor + offset
                if interleavedStride > 1 {
                    for channel in 0..<interleavedStride { sum += channels[0][frame * interleavedStride + channel] }
                } else {
                    for pointer in channels { sum += pointer[frame] }
                }
            }
            output[index] = sum * scale
        }
        return output
    }
}

/// Reads the last unbroken heard audio up to a media time, as `HeardAudioWindowRecorder.recentRun` cuts it, with the
/// recorder's sample rate (#2966). It waits for the tap's queued buffers, so it is called off the main thread.
public typealias HeardAudioReader = @Sendable (_ endingAtMs: Int, _ lastMs: Int) -> (sampleRate: Double, segment: HeardAudioWindow.Segment)?

/// A player that keeps the heard minute and lends a reader of it while one item is the one playing.
public protocol HeardAudioSource: AnyObject {
    /// Nil when that item isn't the one the player's tap is listening to. Called on the main thread.
    func heardAudioReader(itemId: String) -> HeardAudioReader?
}
