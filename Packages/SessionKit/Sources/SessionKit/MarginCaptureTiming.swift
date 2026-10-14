import Foundation

/// Captured at the entry to Add a Margin, before permission, playback handoff or recorder work (#1506).
/// The wall clock locates the tap in an export; durations use uptime so clock corrections can't distort them.
public struct MarginCaptureRequest: Equatable, Sendable {
    public let id: UUID
    public let tappedAt: Date
    public let uptime: TimeInterval
    /// True when `tappedAt` is only when the engine was called: Margins that start from the Live Activity, the
    /// Lock Screen or a widget don't carry the time of the tap, so their figures leave out what came before.
    public let startsAtEngineCall: Bool

    public init(id: UUID = UUID(), tappedAt: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                startsAtEngineCall: Bool = true) {
        self.id = id
        self.tappedAt = tappedAt
        self.uptime = uptime
        self.startsAtEngineCall = startsAtEngineCall
    }

    /// A tap noted as a wall-clock `Date` earlier in the same run: the uptime is that many seconds before now.
    public static func tapped(at date: Date, now: Date = Date(), uptimeNow: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MarginCaptureRequest {
        MarginCaptureRequest(tappedAt: date, uptime: uptimeNow - max(0, now.timeIntervalSince(date)), startsAtEngineCall: false)
    }
}

/// One capture's milestones, retained even when the recorder is restarted. Missing input is explicit,
/// never replaced by the recorder accepting `record()`, or the health check's 100 ms threshold.
public struct MarginCaptureTiming: Equatable, Sendable {
    public let request: MarginCaptureRequest
    private var recorderRequestedMs: Int?
    private var recorderStartedMs: Int?
    private var firstAudioObservedMs: Int?
    private var firstNonSilentObservedMs: Int?
    private var firstInputRoute: String?
    private var recorderInputRoute: String?

    public init(request: MarginCaptureRequest) { self.request = request }

    public mutating func recorderRequested(at uptime: TimeInterval) {
        if recorderRequestedMs == nil { recorderRequestedMs = milliseconds(at: uptime) }
    }

    public mutating func recorderStarted(at uptime: TimeInterval, inputRoute: String?) {
        if recorderStartedMs == nil {
            recorderStartedMs = milliseconds(at: uptime)
            recorderInputRoute = inputRoute
        }
    }

    /// The production AVAudioRecorder exposes meters, not buffer callbacks. These are upper bounds
    /// at the first poll that sees input, explicitly labelled as observations in diagnostics. No speech
    /// is trimmed or gated on the meter. A tone/background noise can also be non-silent input.
    public mutating func observe(_ reading: RecordingCaptureReading?, at uptime: TimeInterval, inputRoute: String?) {
        guard recorderStartedMs != nil, let reading, reading.recorderRunning, reading.capturedMs > 0 else { return }
        if firstAudioObservedMs == nil { firstAudioObservedMs = milliseconds(at: uptime) }
        guard let peak = reading.peakPowerDb, peak.isFinite, peak > -120, firstNonSilentObservedMs == nil else { return }
        firstNonSilentObservedMs = milliseconds(at: uptime)
        firstInputRoute = inputRoute
    }

    public var fields: [String: String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "captureID": request.id.uuidString,
            "tapAt": formatter.string(from: request.tappedAt),
            "tapSource": request.startsAtEngineCall ? "engine_call" : "app_tap",
            "tapToRecorderRequestedMs": recorderRequestedMs.map(String.init) ?? "not_observed",
            "tapToRecorderStartedMs": recorderStartedMs.map(String.init) ?? "not_observed",
            "tapToFirstAudioObservedMs": firstAudioObservedMs.map(String.init) ?? "not_observed",
            "tapToFirstNonSilentObservedMs": firstNonSilentObservedMs.map(String.init) ?? "not_observed",
            "recorderInputRoute": recorderInputRoute ?? "unknown",
            "firstNonSilentInputRoute": firstInputRoute ?? "not_observed",
            "firstAudioTimingMethod": "recorder_clock_poll_upper_bound",
            "firstNonSilentTimingMethod": "meter_poll_upper_bound",
            // Add a Margin has no start tone on this path. Hands-free tones are a different flow.
            "startTone": "not_used",
            "tapToStartToneFinishedMs": "not_applicable"
        ]
    }

    private func milliseconds(at uptime: TimeInterval) -> Int {
        max(0, Int(((uptime - request.uptime) * 1_000).rounded()))
    }
}
