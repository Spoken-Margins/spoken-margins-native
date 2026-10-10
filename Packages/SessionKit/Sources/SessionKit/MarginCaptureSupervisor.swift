import Foundation

/// What a recorder says about the voice capture in progress (#937).
///
/// `capturedMs` is audio the recorder has really taken in, not time on the clock. A recorder that
/// accepted its start but gets no sound from the microphone stays near 0 while `recorderRunning`
/// still reads true, which is how the app once said "Recording" over files holding 22 ms of audio.
public struct RecordingCaptureReading: Equatable, Sendable {
    public var recorderRunning: Bool
    public var capturedMs: Int
    /// False while a stopped recorder's file is still being measured, or could not be read. `capturedMs` is
    /// then only a lower bound, and the recording may hold speech: it is kept, never restarted or discarded.
    public var durationKnown: Bool

    public init(recorderRunning: Bool, capturedMs: Int, durationKnown: Bool = true) {
        self.recorderRunning = recorderRunning
        self.capturedMs = max(0, capturedMs)
        self.durationKnown = durationKnown
    }
}

/// Every number the capture check uses, named so the phone check can tune them.
public enum MarginCaptureTimings {
    /// Audio the recorder must report before the capture counts as started.
    public static let firstAudioMs = 100
    /// How long a start may take on the clock, after the recorder accepted it, before it counts as
    /// not capturing. Bluetooth routes take over a second to settle.
    public static let startGraceMs = 2_000
    /// A started capture whose audio stops growing for this long is stalled.
    public static let stallMs = 2_000
    /// Restarts the app tries by itself before it tells the listener.
    public static let automaticRestarts = 2
    /// The one line between audio worth keeping and an empty recording. At or above it a stopped
    /// capture is never restarted (a restart deletes the file), Try again is refused, and Save keeps the
    /// Margin. Below it, after `judgeAfterMs` on the clock, a recording is empty.
    public static let keepAudioMs = 250
    /// A recording shorter than this on the clock is too brief to judge.
    public static let judgeAfterMs = 1_500
    /// On the clock for at least this long, with under half of it captured, a recording was cut short.
    public static let cutShortAfterMs = 4_000
}

/// Decides, from recorder readings, whether a spoken Margin is really being captured, whether to
/// restart a recorder that never got going, and whether a finished recording holds anything (#937).
///
/// Pure: the app feeds it readings and a clock, and carries out the one action it can return. The
/// screen says "Recording" only while `health` is `.capturing`.
public struct MarginCaptureSupervisor: Equatable, Sendable {
    public enum Health: Equatable, Sendable {
        /// The recorder accepted the start and has not yet reported audio.
        case starting
        /// Audio is arriving.
        case capturing
        /// No audio is arriving, or the recorder stopped.
        case notCapturing(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case recorderStopped = "recorder_stopped"
        case noAudioAfterStart = "no_audio_after_start"
        case audioStalled = "audio_stalled"
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Start a new recorder on a new file. Report back with `captureRestarted` or `restartFailed`.
        case restartCapture
    }

    /// The raw value is the word the diagnostics log uses.
    public enum SaveVerdict: String, Equatable, Sendable {
        case save
        /// Save it, and say part of it may be missing.
        case saveCutShort = "save_cut_short"
        /// Nothing was captured: do not save a Margin with an empty voice.
        case discardEmpty = "discard_empty"
    }

    public private(set) var health: Health = .starting
    public private(set) var restarts = 0
    /// The most audio the current recorder has reported. A recorder that stops reads 0 afterwards, but
    /// what it took in before the stop is still in its file, so this never goes down.
    public var capturedMs: Int { lastCapturedMs }
    /// The current recorder holds enough audio that a stop is worth saving, not restarting.
    public var hasKeepableAudio: Bool { durationUnknown || lastCapturedMs >= MarginCaptureTimings.keepAudioMs }

    private var beganAtMs: Int
    private var lastProgressAtMs: Int
    private var lastCapturedMs = 0
    /// The last reading could not say how much the recorder holds. Unknown is treated as worth keeping.
    private var durationUnknown = false
    private var restartAllowance = MarginCaptureTimings.automaticRestarts

    /// `beganAtMs` is the clock reading when the recorder accepted its start.
    public init(beganAtMs: Int) {
        self.beganAtMs = beganAtMs
        self.lastProgressAtMs = beganAtMs
    }

    /// Call on each poll while recording. A nil reading means the recorder can't tell (a test double,
    /// the watch): the capture counts as running, as it did before this check existed.
    public mutating func observe(_ reading: RecordingCaptureReading?, nowMs: Int) -> Action {
        guard let reading else {
            health = .capturing
            return .none
        }
        durationUnknown = !reading.durationKnown
        if reading.capturedMs > lastCapturedMs {
            lastCapturedMs = reading.capturedMs
            lastProgressAtMs = nowMs
        }
        let reason: Reason?
        if !reading.recorderRunning {
            reason = .recorderStopped
        } else if reading.capturedMs < MarginCaptureTimings.firstAudioMs {
            reason = nowMs - beganAtMs >= MarginCaptureTimings.startGraceMs ? .noAudioAfterStart : nil
        } else if nowMs - lastProgressAtMs >= MarginCaptureTimings.stallMs {
            reason = .audioStalled
        } else {
            reason = nil
        }
        guard let reason else {
            health = reading.capturedMs >= MarginCaptureTimings.firstAudioMs ? .capturing : .starting
            return .none
        }
        health = .notCapturing(reason)
        guard !hasKeepableAudio, restartAllowance > 0 else { return .none }
        restartAllowance -= 1
        return .restartCapture
    }

    /// The restart began a new recording: judge it from scratch.
    public mutating func captureRestarted(nowMs: Int) {
        restarts += 1
        beganAtMs = nowMs
        lastProgressAtMs = nowMs
        lastCapturedMs = 0
        durationUnknown = false
        health = .starting
    }

    /// The restart itself failed (the session would not activate, the recorder would not start).
    public mutating func restartFailed(reason: Reason = .recorderStopped) {
        restartAllowance = 0
        health = .notCapturing(reason)
    }

    /// The listener asked to try again: allow one more restart and check the capture afresh.
    public mutating func listenerRetry(nowMs: Int) {
        restartAllowance = 1
        beganAtMs = nowMs
        lastProgressAtMs = nowMs
        lastCapturedMs = 0
        durationUnknown = false
        health = .starting
    }

    /// Whether the recording that would be saved now holds anything, judged on the current recorder.
    public func saveVerdict(reading: RecordingCaptureReading?, nowMs: Int) -> SaveVerdict {
        guard let reading else { return .save }
        let onClockMs = max(0, nowMs - beganAtMs)
        guard onClockMs >= MarginCaptureTimings.judgeAfterMs else { return .save }
        // A recorder that stopped and whose file can't be measured may hold speech: keep it.
        if !reading.durationKnown { return .saveCutShort }
        let capturedMs = max(lastCapturedMs, reading.capturedMs)
        if capturedMs < MarginCaptureTimings.keepAudioMs { return .discardEmpty }
        if onClockMs >= MarginCaptureTimings.cutShortAfterMs, capturedMs * 2 < onClockMs { return .saveCutShort }
        return .save
    }
}

extension MarginCaptureSupervisor.Health {
    /// A fixed word for the diagnostics log.
    public var diagnosticName: String {
        switch self {
        case .starting: "starting"
        case .capturing: "capturing"
        case .notCapturing(let reason): "not_capturing:\(reason.rawValue)"
        }
    }
}
