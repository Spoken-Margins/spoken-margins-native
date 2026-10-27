import Foundation

/// How much faster than the listener a voice has to render to be called healthy (owner, 2026-10-25, #2701):
/// at least 1.25 times the listening speed, which is 2.5x real time at 2x listening. Headroom is the real-time
/// factor divided by the listening speed, so a voice is healthy when its headroom is at least this.
public enum VoiceHeadroom {
    public static let healthyMultiple = 1.25

    public static func isHealthy(headroom: Double) -> Bool { headroom >= healthyMultiple }
}

/// One chunk a voice rendered on this phone (#2701). A small value that other code can reuse: the burst-pacing
/// policy (#2703) reads `realTimeFactor` and `headroom` from it. It holds no text, title or address.
public struct VoiceRenderChunk: Equatable, Sendable {
    /// `supertonic`, `kitten` or a later engine's name.
    public var engine: String
    /// Engine and voice, such as `supertonic:F1` or `kitten`.
    public var voiceId: String
    /// Seconds of audio that came back.
    public var audioSeconds: TimeInterval
    /// Wall-clock seconds the render took.
    public var computeSeconds: TimeInterval
    /// The listener's speed: audio is used up this many seconds per second.
    public var listeningSpeed: Double
    public var thermalAtStart: SpeechThermalLevel
    public var thermalAtEnd: SpeechThermalLevel
    public var isInBackground: Bool
    /// Nil when the phone can't say.
    public var isCharging: Bool?
    public var isLowPowerModeEnabled: Bool

    public init(
        engine: String, voiceId: String, audioSeconds: TimeInterval, computeSeconds: TimeInterval,
        listeningSpeed: Double, thermalAtStart: SpeechThermalLevel, thermalAtEnd: SpeechThermalLevel,
        isInBackground: Bool, isCharging: Bool? = nil, isLowPowerModeEnabled: Bool
    ) {
        self.engine = engine
        self.voiceId = voiceId
        self.audioSeconds = audioSeconds
        self.computeSeconds = computeSeconds
        self.listeningSpeed = listeningSpeed
        self.thermalAtStart = thermalAtStart
        self.thermalAtEnd = thermalAtEnd
        self.isInBackground = isInBackground
        self.isCharging = isCharging
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// False for a chunk with no render time or no audio, which says nothing about pace.
    public var isMeasurable: Bool {
        computeSeconds > 0 && audioSeconds > 0 && computeSeconds.isFinite && audioSeconds.isFinite
            && listeningSpeed > 0 && listeningSpeed.isFinite
    }

    /// Seconds of audio made per second of rendering.
    public var realTimeFactor: Double { audioSeconds / computeSeconds }
    /// The real-time factor over the listening speed. 1.0 only just keeps up.
    public var headroom: Double { realTimeFactor / listeningSpeed }
    public var isHealthy: Bool { VoiceHeadroom.isHealthy(headroom: headroom) }

    func with(charging: Bool?) -> VoiceRenderChunk {
        var copy = self
        copy.isCharging = charging
        return copy
    }
}

/// What the on-device player tells telemetry, from any thread. The app turns each into a Diagnostics event.
public enum VoiceTelemetryEvent: Equatable, Sendable {
    case chunk(VoiceRenderChunk)
    /// Narration moved to another voice. `to` is a voice id, or `ios` for the iOS voice.
    case switched(to: String, reason: String)
    /// Narration went back to the listener's chosen voice.
    case restored(reason: String)
    /// Playback stopped or moved to another item: write the session line and start a new session.
    case sessionEnded
}

/// One Diagnostics event: a kind and string fields, as `recordDeveloperDiagnostic` takes them.
public struct VoiceTelemetryOutput: Equatable, Sendable {
    public var kind: String
    public var fields: [String: String]
}

/// Numbers for one listening session, kept per chunk (#2701). No item, text or address goes in.
public struct VoiceRenderTelemetry: Sendable {
    public static let chunkKind = "voicepace.chunk"
    public static let switchKind = "voicepace.switch"
    public static let summaryKind = "voicepace.summary"
    /// A gap longer than this between two observations is a pause, not time spent in a thermal state.
    public static let longestCountedGap: TimeInterval = 300

    /// The voice the listener chose. A switch to anything else is a fallback.
    public let chosenVoice: String
    public private(set) var currentVoice: String
    private var realTimeFactors: [Double] = []
    private var healthyChunks = 0
    private var fallbackCount = 0
    private var switchCount = 0
    private var thermalSeconds: [SpeechThermalLevel: TimeInterval] = [:]
    private var lastThermal: (level: SpeechThermalLevel, at: TimeInterval)?

    public init(chosenVoice: String) {
        self.chosenVoice = chosenVoice
        self.currentVoice = chosenVoice
    }

    /// Handles one event at `uptime` (the system uptime, in seconds, when it happened). Returns the events to log.
    public mutating func handle(_ event: VoiceTelemetryEvent, uptime: TimeInterval, isCharging: Bool? = nil) -> [VoiceTelemetryOutput] {
        switch event {
        case .chunk(let chunk):
            let chunk = chunk.isCharging == nil ? chunk.with(charging: isCharging) : chunk
            guard chunk.isMeasurable else { return [] }
            observe(chunk.thermalAtStart, at: uptime - chunk.computeSeconds)
            observe(chunk.thermalAtEnd, at: uptime)
            realTimeFactors.append(chunk.realTimeFactor)
            if chunk.isHealthy { healthyChunks += 1 }
            return [VoiceTelemetryOutput(kind: Self.chunkKind, fields: Self.fields(chunk))]
        case .switched(let to, let reason):
            return switchVoice(to: to, reason: reason)
        case .restored(let reason):
            return switchVoice(to: chosenVoice, reason: reason)
        case .sessionEnded:
            guard !realTimeFactors.isEmpty || switchCount > 0 else { return [] }
            if let last = lastThermal { observe(last.level, at: uptime) }
            let line = VoiceTelemetryOutput(kind: Self.summaryKind, fields: summaryFields())
            reset()
            return [line]
        }
    }

    private mutating func switchVoice(to: String, reason: String) -> [VoiceTelemetryOutput] {
        guard to != currentVoice else { return [] }
        let from = currentVoice
        currentVoice = to
        switchCount += 1
        if to != chosenVoice { fallbackCount += 1 }
        return [VoiceTelemetryOutput(kind: Self.switchKind, fields: ["from": from, "to": to, "reason": reason])]
    }

    private mutating func observe(_ level: SpeechThermalLevel, at time: TimeInterval) {
        if let last = lastThermal {
            let gap = time - last.at
            if gap > 0 { thermalSeconds[last.level, default: 0] += min(gap, Self.longestCountedGap) }
        }
        lastThermal = (level, max(time, lastThermal?.at ?? time))
    }

    private mutating func reset() {
        currentVoice = chosenVoice
        realTimeFactors = []
        healthyChunks = 0
        fallbackCount = 0
        switchCount = 0
        thermalSeconds = [:]
        lastThermal = nil
    }

    /// Nearest-rank percentile (so each answer is a rate the phone really made). Nil with no values.
    public static func percentile(_ fraction: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    func summaryFields() -> [String: String] {
        var fields: [String: String] = [
            "chunks": String(realTimeFactors.count),
            "healthy_chunks": String(healthyChunks),
            "healthy_headroom": Self.number(VoiceHeadroom.healthyMultiple),
            "fallbacks": String(fallbackCount),
            "switches": String(switchCount),
            "chosen_voice": chosenVoice,
        ]
        if let median = Self.percentile(0.5, of: realTimeFactors) { fields["median_rtf"] = Self.number(median) }
        if let p10 = Self.percentile(0.1, of: realTimeFactors) { fields["p10_rtf"] = Self.number(p10) }
        for level in [SpeechThermalLevel.nominal, .fair, .serious, .critical] {
            fields["thermal_\(level.rawValue)_s"] = Self.number(thermalSeconds[level] ?? 0)
        }
        return fields
    }

    static func fields(_ chunk: VoiceRenderChunk) -> [String: String] {
        [
            "engine": chunk.engine,
            "voice": chunk.voiceId,
            "audio_s": number(chunk.audioSeconds),
            "compute_s": number(chunk.computeSeconds),
            "rtf": number(chunk.realTimeFactor),
            "listening_speed": number(chunk.listeningSpeed),
            "headroom": number(chunk.headroom),
            "healthy": String(chunk.isHealthy),
            "thermal_start": chunk.thermalAtStart.rawValue,
            "thermal_end": chunk.thermalAtEnd.rawValue,
            "background": String(chunk.isInBackground),
            "charging": chunk.isCharging.map(String.init) ?? "unknown",
            "low_power": String(chunk.isLowPowerModeEnabled),
        ]
    }

    private static func number(_ value: Double) -> String { String(format: "%.2f", value) }
}
