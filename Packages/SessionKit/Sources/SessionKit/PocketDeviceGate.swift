import Foundation

/// One timed render of `PocketDeviceGate.checkSentence` on this phone.
public struct PocketRenderMeasurement: Equatable, Sendable {
    /// Seconds of audio the render produced.
    public var audioSeconds: Double
    /// Wall-clock seconds the render took, from first call to last sample.
    public var renderSeconds: Double

    public init(audioSeconds: Double, renderSeconds: Double) {
        self.audioSeconds = audioSeconds
        self.renderSeconds = renderSeconds
    }

    /// Seconds of audio per second of rendering, or nil when the numbers can't be trusted.
    public var speed: Double? {
        guard audioSeconds.isFinite, renderSeconds.isFinite, audioSeconds > 0, renderSeconds > 0 else { return nil }
        return audioSeconds / renderSeconds
    }
}

/// Whether Pocket TTS may be offered on this phone (#461, part of #212). A short on-device speed
/// check renders a fixed sentence once; a phone that can't keep ahead of playback never sees the
/// voice. Pure policy: the caller times the render, this decides.
public struct PocketDeviceGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case offer
        /// Rendering was slower than the threshold.
        case tooSlow(speed: Double, threshold: Double)
        /// The measurement was unusable (zero, negative or NaN time; too little audio to trust).
        /// Treated as "don't offer", but the caller may measure again.
        case inconclusive
    }

    /// The least speed any phone may have, in seconds of audio per second of rendering. Below
    /// this, playback would catch up with the renderer.
    public static let floorSpeed: Double = 2

    /// The threshold never drops below real time: slower than that, playback outruns the renderer.
    public static let minimumThreshold: Double = 1

    /// How much slower than the owner's measured phone a listener's phone may be.
    public static let defaultMargin: Double = 0.25

    /// The sentence the speed check renders. Fixed so every phone is timed on the same work.
    public static let checkSentence = "The quick brown fox jumps over the lazy dog, and then walks quietly back home along the river."

    /// Audio shorter than this says little about speed: start-up cost dominates.
    public static let minimumAudioSeconds: Double = 3

    /// The speed the owner's iPhone 17 Pro reached, warm, with Low Power Mode on (VoiceBench, #461).
    /// Nil until that run is posted on #212.
    public var referencePhoneSpeed: Double?
    public var margin: Double

    public init(referencePhoneSpeed: Double? = nil, margin: Double = PocketDeviceGate.defaultMargin) {
        self.referencePhoneSpeed = referencePhoneSpeed
        self.margin = margin
    }

    /// 2x real time, or the reference phone's speed minus the margin when that is lower, but never
    /// below real time.
    public var threshold: Double {
        guard let reference = referencePhoneSpeed, reference.isFinite, reference > 0 else { return Self.floorSpeed }
        let margin = margin.isFinite ? max(0, margin) : 0
        return min(Self.floorSpeed, max(Self.minimumThreshold, reference - margin))
    }

    public func decide(_ measurement: PocketRenderMeasurement) -> Decision {
        guard measurement.audioSeconds >= Self.minimumAudioSeconds, let speed = measurement.speed else {
            return .inconclusive
        }
        return speed >= threshold ? .offer : .tooSlow(speed: speed, threshold: threshold)
    }
}
