import Foundation

/// C3: how long a Spoken Margins Live Activity may stay on screen once listening stops.
///
/// Testers took a Live Activity that outlived playback for a broken app. These rules keep it honest:
/// - While listening or recording, the activity has no stale date, so playback publishes nothing extra.
/// - While paused, it carries a stale date at the idle deadline and is ended once the deadline passes.
/// - When an audio interruption ends without permission to resume (another app kept the audio), a
///   paused activity ends at once. An ordinary interruption such as a phone call only pauses, so the
///   activity stays and the listener can resume afterwards.
/// - Once ended, it stays ended until listening resumes; a later paused refresh doesn't bring it back.
/// - Another app took over the audio (#245): while the app is in the background after a pause, it
///   checks every few seconds whether other audio is playing. If it is and no phone call is
///   active, the card ends at once: the listener has moved to another audio source.
/// - Owner decision (#193, option 2): when the listener pauses with the phone locked, the removal
///   is handed to iOS after a short grace, so the card goes on time even if the app never runs
///   again. Pauses caused by an interruption (a phone call, another app) never hand off.
public struct LiveActivityLifecycle: Equatable, Sendable {
    /// Thirty minutes covers a coffee break or a phone call, and is short enough that a listener
    /// who has moved on doesn't find a paused card on the Lock Screen for the rest of the day.
    public static let pausedIdleLimit: TimeInterval = 30 * 60
    /// A quick pause and resume with the phone locked keeps the card. iOS gives a background
    /// task about 30 seconds, so the hand-off must happen well inside that.
    public static let lockedPauseGrace: TimeInterval = 20
    /// How often the app checks for another app's audio during that window (#245).
    public static let otherAudioCheckInterval: TimeInterval = 5

    public enum EndReason: String, Equatable, Sendable {
        case idleLimit = "idle_limit"
        case interruptionWithoutResume = "interruption_without_resume"
        /// Ended with a dismissal at the idle deadline; iOS removes it then.
        case handedOffToSystem = "handed_off_to_system"
        /// Another app is playing audio and no call is active (#245).
        case otherAudioTookOver = "other_audio_took_over"
    }

    public enum Decision: Equatable, Sendable {
        /// Show or update the activity. `staleDate` is nil while listening.
        case show(staleDate: Date?)
        /// End the activity now.
        case end(EndReason)
        /// Already ended for this pause: don't publish, or the activity would come back.
        case hidden(EndReason)
    }

    private var pausedSessionId: String?
    private var pausedSince: Date?
    private var endReason: EndReason?
    private var pauseCausedByInterruption = false
    private var handOffAt: Date?

    public init() {}

    /// When the paused activity should end, if it is paused and still showing.
    public var idleDeadline: Date? {
        guard endReason == nil, let pausedSince else { return nil }
        return pausedSince.addingTimeInterval(Self.pausedIdleLimit)
    }

    /// Call for every state the Live Activity would publish.
    /// - Parameters:
    ///   - isListening: playing, starting, or recording a Margin.
    ///   - isPaused: the session is paused and not recording.
    public mutating func observe(sessionId: String?, isListening: Bool, isPaused: Bool, now: Date) -> Decision {
        guard let sessionId, !isListening, isPaused else {
            // An interruption can be reported just before its pause arrives; keep that mark
            // until a pause has actually happened and listening resumed.
            if pausedSince != nil || endReason != nil || !isListening { reset() }
            return .show(staleDate: nil)
        }
        if pausedSessionId != sessionId || pausedSince == nil {
            pausedSessionId = sessionId
            pausedSince = now
            endReason = nil
        }
        if let endReason {
            return .hidden(endReason)
        }
        guard let deadline = idleDeadline else { return .show(staleDate: nil) }
        if now >= deadline {
            endReason = .idleLimit
            return .end(.idleLimit)
        }
        return .show(staleDate: deadline)
    }

    /// Call when `AVAudioSession` reports that an interruption ended. Returns `.end` when a paused
    /// activity should go now, or nil when nothing changes.
    public mutating func audioInterruptionEnded(_ end: InterruptionEnd) -> Decision? {
        guard !end.iosAllowsAudioToStart, pausedSessionId != nil, endReason == nil else { return nil }
        endReason = .interruptionWithoutResume
        return .end(.interruptionWithoutResume)
    }

    /// An audio interruption began (a phone call, or another app took the audio). The pause it
    /// causes never hands off to iOS, so the card is there to resume after a call.
    public mutating func audioInterruptionBegan() {
        pauseCausedByInterruption = true
        handOffAt = nil
    }

    /// When a paused card should be handed to iOS: the grace end, if the app is in the background
    /// and the listener (not an interruption) paused. Nil when nothing should be scheduled.
    public mutating func scheduleHandOff(appInBackground: Bool, now: Date) -> Date? {
        guard appInBackground, !pauseCausedByInterruption, idleDeadline != nil else {
            handOffAt = nil
            return nil
        }
        if handOffAt == nil { handOffAt = now.addingTimeInterval(Self.lockedPauseGrace) }
        return handOffAt
    }

    /// Another app's audio was checked while ours is paused (#245). Returns `.end` when another app is
    /// playing and no phone call is active, including for a card already handed off to iOS (it's
    /// still on screen until the deadline). A phone call keeps the card, so the listener can resume.
    public mutating func otherAudioChecked(isOtherAudioPlaying: Bool, isPhoneCallActive: Bool) -> Decision? {
        guard isOtherAudioPlaying, !isPhoneCallActive, pausedSessionId != nil,
              endReason == nil || endReason == .handedOffToSystem else { return nil }
        endReason = .otherAudioTookOver
        handOffAt = nil
        return .end(.otherAudioTookOver)
    }

    /// Whether a paused card is (or may still be) on screen: worth checking for another app's audio.
    public var isPausedCardOnScreen: Bool {
        pausedSessionId != nil && (endReason == nil || endReason == .handedOffToSystem)
    }

    /// The app is back in front: a pending hand-off is dropped (the app can manage the card again).
    public mutating func appReturnedToForeground() {
        handOffAt = nil
    }

    /// Called when the grace timer fires. Returns the date iOS should remove the card, or nil when
    /// the listener resumed, the app came back, or an interruption took over in the meantime.
    public mutating func handOffIfDue(appInBackground: Bool, now: Date) -> Date? {
        guard appInBackground, !pauseCausedByInterruption,
              let handOffAt, now >= handOffAt,
              let deadline = idleDeadline else { return nil }
        self.handOffAt = nil
        endReason = .handedOffToSystem
        return deadline
    }

    private mutating func reset() {
        pausedSessionId = nil
        pausedSince = nil
        endReason = nil
        pauseCausedByInterruption = false
        handOffAt = nil
    }
}
