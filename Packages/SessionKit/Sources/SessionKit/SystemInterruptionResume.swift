import Foundation

/// The one owner of "does playback resume by itself after a system interruption" (#3032).
///
/// The question used to be answered twice, by the AVPlayer client (`AudioPlaybackInterruptionResumePolicy`) and by the
/// Supertonic client (`shouldResumeAfterInterruption`, a bare flag written in eight places), and the two disagreed at
/// the edges. Both clients now only report events here and obey the answer; neither keeps a resume flag of its own.
///
/// The rules, in one place:
/// - An interruption (a call, Siri, an alarm) that finds the source playing and pauses it arms an automatic resume.
/// - An interruption that finds nothing playing changes nothing: if an earlier interruption already paused the source,
///   its resume stays armed, because that interruption is still going on.
/// - A lost route (headphones unplugged, Bluetooth gone) never resumes by itself, whether or not it paused anything:
///   resuming out of the phone's speaker after the listener pulled the plug is not what they asked for.
/// - The interruption ending resumes only when it is armed and iOS says the app should resume. Any end spends the
///   arming, so a late second end cannot resume twice.
/// - The listener's own Play, Pause, Stop or a new item cancels the arming.
/// - When the other audio stops without iOS reporting an end (a message announcement, #1434), that counts as an end
///   with "should resume", as long as the source is still paused.
public struct SystemInterruptionResume: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// An audio-session interruption began.
        case interruption
        /// The output in use went away.
        case routeLost
    }

    /// Whether an automatic resume is waiting for the interruption to end.
    public private(set) var isArmed = false

    public init() {}

    /// A system pause arrived. Returns `wasPlaying`, which is whether the source was playing and so was paused by it.
    @discardableResult
    public mutating func began(_ cause: Cause, wasPlaying: Bool) -> Bool {
        switch cause {
        case .interruption:
            if wasPlaying { isArmed = true }
        case .routeLost:
            isArmed = false
        }
        return wasPlaying
    }

    /// The interruption ended. True when playback should resume now: armed, and iOS says audio may start again.
    /// Spends the arming either way.
    public mutating func ended(_ end: InterruptionEnd) -> Bool {
        defer { isArmed = false }
        return isArmed && end.iosAllowsAudioToStart
    }

    /// The other audio stopped without iOS reporting an end. True when playback should resume now: armed, and the
    /// source is still paused (a client that can see its transport passes false once the listener took over).
    /// Spends the arming either way.
    public mutating func otherAudioStopped(sourceStillPaused: Bool = true) -> Bool {
        defer { isArmed = false }
        return isArmed && sourceStillPaused
    }

    /// The listener took over, or a new item started: the automatic resume no longer applies.
    public mutating func cancelAutomaticResume() {
        isArmed = false
    }
}

/// Why speech paused, or didn't resume, without the listener asking (#538). Recorded in the
/// playback event log, which timestamps each entry, so a device report shows what stopped
/// narration and when, instead of a bare "paused".
public enum SpeechSystemPause: Equatable, Sendable {
    /// An audio-session interruption began. `reasonRawValue` is the notification's
    /// `AVAudioSessionInterruptionReasonKey`, when it has one.
    case interruptionBegan(reasonRawValue: UInt?)
    /// An audio-session interruption ended. When iOS does not say audio may start again, speech stays paused.
    case interruptionEnded(InterruptionEnd)
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
        case .interruptionEnded(let end):
            fields["shouldResume"] = String(end.iosAllowsAudioToStart) // the log key stays: device reports and tests read it
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

/// The place the system paused a podcast or recording at, and when, until it is resumed or the listener moves it
/// (#1975). Where the source resumes from after the interruption is decided here: a step back from the place,
/// by how long the pause lasted (#3144, #3032 slice 3). `SessionEngine` reports the pause and asks.
struct InterruptionResumePoint {
    private var mark: (sessionId: String, mediaTimeMs: Int, at: Date)?

    /// The system paused the source at `mediaTimeMs` of the session. Text, read from a character, passes nil.
    mutating func paused(sessionId: String, mediaTimeMs: Int?, at: Date) {
        mark = mediaTimeMs.map { (sessionId, $0, at) }
    }

    /// The listener played, paused, moved it, or the interruption was resumed: no step back applies.
    mutating func forget() {
        mark = nil
    }

    /// How far back to step now, or nil when the source is not where the system left it (the listener or another
    /// event moved it, or it is another session). 0 means resume as it is.
    func rewindMs(sessionId: String, mediaTimeMs: Int?, now: () -> Date) -> (pausedAtMs: Int, rewindMs: Int)? {
        guard let mark, mark.sessionId == sessionId, mediaTimeMs == mark.mediaTimeMs else { return nil }
        return (mark.mediaTimeMs, InterruptionRewind.rewindMs(pausedForSeconds: now().timeIntervalSince(mark.at)))
    }
}
