import Foundation

/// How fast the phone renders narration compared with how fast the listener uses it up (#540).
///
/// A player that reaches the next chunk before it is rendered goes silent, and in Low Power Mode with the
/// phone locked the owner heard exactly that. Whether rendering fell behind playback was only an inference,
/// because diagnostics kept no render times. This keeps, per chunk the phone actually rendered, the seconds
/// of audio made per second of rendering, next to the playback rate that has to be beaten, Low Power Mode
/// and heat. Chunks recovered from disk or from prepared audio render nothing and are not recorded.
public struct RenderPaceLog: Sendable {
    public struct Sample: Equatable, Sendable {
        public var chunkStartOffset: Int
        /// Wall-clock seconds the render took, from asking for it to having the audio.
        public var renderSeconds: TimeInterval
        /// Length of the audio that came back.
        public var audioSeconds: TimeInterval
        /// The listener's speed: audio is used up this many seconds per second.
        public var playbackRate: Double
        public var isLowPowerModeEnabled: Bool
        public var thermal: SpeechThermalLevel

        public init(
            chunkStartOffset: Int,
            renderSeconds: TimeInterval,
            audioSeconds: TimeInterval,
            playbackRate: Double,
            isLowPowerModeEnabled: Bool,
            thermal: SpeechThermalLevel
        ) {
            self.chunkStartOffset = chunkStartOffset
            self.renderSeconds = renderSeconds
            self.audioSeconds = audioSeconds
            self.playbackRate = playbackRate
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.thermal = thermal
        }

        /// Seconds of audio made per second of rendering.
        public var audioPerRenderSecond: Double { audioSeconds / renderSeconds }

        /// True when rendering made audio at least as fast as playback used it, so the buffer never shrinks.
        public var keepsUpWithPlayback: Bool { audioPerRenderSecond >= playbackRate }
    }

    /// Chunks recorded.
    public private(set) var count = 0
    /// Chunks that rendered slower than they played.
    public private(set) var behindCount = 0
    /// The chunk with the fewest seconds of audio per second of rendering.
    public private(set) var slowest: Sample?
    public private(set) var latest: Sample?

    public init() {}

    /// Records a render. A sample with no render time or no audio says nothing about pace and is ignored.
    /// Returns whether it was recorded.
    @discardableResult
    public mutating func record(_ sample: Sample) -> Bool {
        guard sample.renderSeconds > 0, sample.audioSeconds > 0, sample.renderSeconds.isFinite, sample.audioSeconds.isFinite else {
            return false
        }
        count += 1
        if !sample.keepsUpWithPlayback { behindCount += 1 }
        latest = sample
        if slowest.map({ sample.audioPerRenderSecond < $0.audioPerRenderSecond }) ?? true { slowest = sample }
        return true
    }

    /// One line for the diagnostics export: `12 chunks, 3 behind playback; slowest 0.62x (11.4 s of audio in
    /// 18.4 s, playing at 0.88x, at 4210, Low Power Mode on, thermal fair); latest 1.90x`. Positions are
    /// offsets into the text, never text.
    public var summary: String {
        guard let slowest, let latest else { return "no chunks rendered" }
        let slowestConditions = (slowest.isLowPowerModeEnabled ? "Low Power Mode on" : "Low Power Mode off")
            + ", thermal \(slowest.thermal.rawValue)"
        return "\(count) chunks, \(behindCount) behind playback; "
            + "slowest \(Self.times(slowest.audioPerRenderSecond)) "
            + "(\(Self.seconds(slowest.audioSeconds)) of audio in \(Self.seconds(slowest.renderSeconds)), "
            + "playing at \(Self.times(slowest.playbackRate)), at \(slowest.chunkStartOffset), \(slowestConditions)); "
            + "latest \(Self.times(latest.audioPerRenderSecond))"
    }

    private static func times(_ value: Double) -> String { String(format: "%.2fx", value) }
    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
}
