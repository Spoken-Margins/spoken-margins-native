import Foundation

/// Why speech paused, or didn't resume, without the listener asking (#538). Recorded in the
/// playback event log, which timestamps each entry, so a device report shows what stopped
/// narration and when, instead of a bare "paused".
public enum SpeechSystemPause: Equatable, Sendable {
    /// An audio-session interruption began. `reasonRawValue` is the notification's
    /// `AVAudioSessionInterruptionReasonKey`, when it has one.
    case interruptionBegan(reasonRawValue: UInt?)
    /// An audio-session interruption ended. Without `shouldResume`, speech stays paused.
    case interruptionEnded(shouldResume: Bool)
    /// The output in use went away (headphones unplugged, Bluetooth disconnected).
    case routeLost
    case mediaServicesReset

    public var kind: String {
        switch self {
        case .interruptionBegan: "speech.interruption_began"
        case .interruptionEnded: "speech.interruption_ended"
        case .routeLost: "speech.route_lost"
        case .mediaServicesReset: "speech.media_services_reset"
        }
    }

    /// - Parameters:
    ///   - acted: whether this event paused speech, or for an ended interruption, asked to resume it.
    ///     Whether the resume happened is a separate `SpeechInterruptionResume` entry.
    ///   - appState: the app's state then ("active", "inactive", "background").
    public func fields(acted: Bool, appState: String, lowPowerMode: Bool) -> [String: String] {
        var fields = ["appState": appState, "lowPowerMode": String(lowPowerMode)]
        switch self {
        case .interruptionBegan(let reason):
            fields["reason"] = Self.interruptionReasonName(reason)
            fields["paused"] = String(acted)
        case .interruptionEnded(let shouldResume):
            fields["shouldResume"] = String(shouldResume)
            fields["resumeRequested"] = String(acted)
        case .routeLost, .mediaServicesReset:
            fields["paused"] = String(acted)
        }
        return fields
    }

    /// `AVAudioSession.InterruptionReason` raw values. iOS 16 and later no longer send
    /// "app_was_suspended"; an interruption while the app was suspended arrives only when it wakes,
    /// so its log time is the wake, and it reads "default" or "none". "route_disconnected" is a lost
    /// Bluetooth or wired route. Values this build doesn't name are kept as numbers.
    static func interruptionReasonName(_ raw: UInt?) -> String {
        switch raw {
        case nil: "none"
        case 0?: "default"
        case 1?: "app_was_suspended"
        case 2?: "built_in_mic_muted"
        case 4?: "route_disconnected"
        case let other?: "raw_\(other)"
        }
    }
}

/// What came of a resume an ended interruption asked for (#538). Logged after the attempt, so a
/// device report doesn't read a request as a resume when the audio session then refused to start.
public enum SpeechInterruptionResume: Equatable, Sendable {
    case resumed
    /// Nothing was paused for the interruption by the time it ended, so nothing resumed.
    case skipped
    case failed(reason: String)

    public var kind: String { "speech.interruption_resume" }

    public var fields: [String: String] {
        switch self {
        case .resumed: ["outcome": "resumed"]
        case .skipped: ["outcome": "skipped"]
        case .failed(let reason): ["outcome": "failed", "error": reason]
        }
    }

    /// The value the app's `speechPlaybackInterruption` diagnostic has always shown.
    public var diagnostic: String {
        switch self {
        case .resumed: "resumed"
        case .skipped: "resume_skipped"
        case .failed(let reason): "resume_failed:\(reason)"
        }
    }
}
