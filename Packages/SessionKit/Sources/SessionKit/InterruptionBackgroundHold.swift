import Foundation

/// Keeps a backgrounded app running while an audio interruption lasts, and resumes when the other audio stops
/// (#1434).
///
/// A message announced through AirPods interrupts narration. The app pauses and asks to resume when iOS says the
/// interruption ended. The hold asks iOS for background time from the moment the interruption begins, so the app
/// isn't suspended while it waits. The owner's phone then showed that for an announcement iOS never says the
/// interruption ended at all: the app stayed awake for 12.7 s, heard nothing, and only resumed on Play
/// (build 32, `437fbc9`). So while it holds, the hold also watches the audio session itself. Once no other audio
/// plays and iOS no longer hints that secondary audio should be silenced, and that stays true for a short settle
/// time within a short announcement window, it activates the session and runs the same resume an "ended, should
/// resume" would. These signals can't distinguish an announcement from another app being paused; the window
/// limits that ambiguity, but cannot eliminate it. A real end, the
/// listener's own Play, Pause or Stop, or the system taking the time back all stop the watch, and a session that
/// can't be activated (a phone call) leaves playback paused. A failed activation or watch timeout stops the watch
/// but keeps the background time, so the app can still receive a real interruption end.
///
/// Each hold leaves a `speech.interruption_hold` event saying how the wait ended and how long it lasted, so a
/// device export shows whether iOS sent the end (`ended`), the other audio stopped (`other_audio_stopped`), or the
/// app gave up waiting. A failed activation or watch timeout records an additional event when the watch stops.
@MainActor
public final class InterruptionBackgroundHold {
    public typealias Begin = NarrationStartupProtection.Begin
    public typealias Record = NarrationStartupProtection.Record
    /// Runs `work` on the main actor after `delay` seconds.
    public typealias Schedule = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    /// The latest hold or watch outcome. `listener_acted`: Play, Pause or a new item before iOS reported the end.
    /// `other_audio_stopped`: the watch saw the other audio stop and resumed. `activation_failed`: it saw the other
    /// audio stop but the session couldn't be activated, so playback stayed paused. `other_audio_still_playing`:
    /// the watch window ran out with the other audio still playing.
    public enum Outcome: String, Sendable {
        case held, unavailable, ended, listenerActed = "listener_acted", expired
        case otherAudioStopped = "other_audio_stopped"
        case activationFailed = "activation_failed"
        case otherAudioStillPlaying = "other_audio_still_playing"
    }

    /// What the audio session says about other apps' audio.
    public struct OtherAudio: Equatable, Sendable {
        public var isPlaying: Bool
        public var secondaryShouldBeSilenced: Bool
        public var isClear: Bool { !isPlaying && !secondaryShouldBeSilenced }

        public init(isPlaying: Bool, secondaryShouldBeSilenced: Bool) {
            self.isPlaying = isPlaying
            self.secondaryShouldBeSilenced = secondaryShouldBeSilenced
        }
    }

    /// How to watch for the other audio stopping. `activate` returns nil when the session is active, or why not.
    public struct OtherAudioWatch {
        public var probe: @MainActor () -> OtherAudio
        public var activate: @MainActor () -> String?
        public var pollInterval: TimeInterval
        /// How long the other audio must stay clear before resuming, so a gap between two sounds isn't taken
        /// for the end.
        public var settle: TimeInterval
        /// How long from `.began` to allow a fallback resume, including settling. This is a bounded announcement
        /// heuristic, not a signal of session ownership. After it runs out, only a real end can resume playback.
        public var window: TimeInterval
        /// How long to keep the background time after resuming, so the app isn't suspended before playback starts.
        public var releaseDelay: TimeInterval

        public init(
            probe: @escaping @MainActor () -> OtherAudio,
            activate: @escaping @MainActor () -> String?,
            pollInterval: TimeInterval = 0.5,
            settle: TimeInterval = 1.0,
            window: TimeInterval = 15,
            releaseDelay: TimeInterval = 3
        ) {
            self.probe = probe
            self.activate = activate
            self.pollInterval = pollInterval
            self.settle = settle
            self.window = window
            self.releaseDelay = releaseDelay
        }
    }

    public static let eventKind = "speech.interruption_hold"

    private let begin: Begin
    private let record: Record
    private let now: () -> Date
    private let watch: OtherAudioWatch?
    private let schedule: Schedule
    private var release: (@MainActor () -> Void)?
    private var heldSince: Date?
    private var holdCount = 0
    private var resume: (@MainActor () -> Void)?
    private var clearSince: Date?

    public private(set) var outcome: Outcome?
    public var isHolding: Bool { release != nil }

    public init(
        begin: @escaping Begin,
        record: @escaping Record,
        now: @escaping () -> Date = Date.init,
        otherAudioWatch: OtherAudioWatch? = nil,
        schedule: @escaping Schedule = InterruptionBackgroundHold.mainQueueSchedule
    ) {
        self.begin = begin
        self.record = record
        self.now = now
        self.watch = otherAudioWatch
        self.schedule = schedule
    }

    public static let mainQueueSchedule: Schedule = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }

    /// An interruption paused narration and asked to resume when it ends. With `resume`, the hold also resumes
    /// once the other audio stops (see the type's notes). A second call while holding does nothing.
    public func interruptionBegan(resumeWhenOtherAudioStops resume: (@MainActor () -> Void)? = nil) {
        guard release == nil else { return }
        let started = now()
        let hold = holdCount + 1
        let granted = begin("Audio interruption wait") { [weak self] in
            // A late expiry of an earlier hold must not end the current one.
            guard let self, self.holdCount == hold, self.release != nil else { return }
            self.finish(as: .expired)
        }
        guard let granted else {
            outcome = .unavailable
            record(Self.eventKind, ["outcome": Outcome.unavailable.rawValue])
            return
        }
        holdCount = hold
        heldSince = started
        release = granted
        outcome = .held
        clearSince = nil
        self.resume = resume
        if resume != nil, let watch { scheduleCheck(hold: hold, after: watch.pollInterval) }
    }

    /// iOS reported the end of the interruption, with or without a request to resume. It takes precedence: the
    /// watch stops and the player's own end handling decides.
    public func interruptionEnded() {
        finish(as: .ended)
    }

    /// The listener's own Play, Pause, Stop or a new item took over before iOS reported the end.
    public func listenerActed() {
        finish(as: .listenerActed)
    }

    private func scheduleCheck(hold: Int, after delay: TimeInterval) {
        schedule(delay) { [weak self] in self?.check(hold: hold) }
    }

    private func check(hold: Int) {
        guard let watch, holdCount == hold, release != nil, resume != nil, let started = heldSince else { return }
        let time = now()
        // Check before probing or activating: even a delayed clear-audio callback must respect the deadline.
        guard time.timeIntervalSince(started) < watch.window else {
            stopWatching(as: .otherAudioStillPlaying)
            return
        }
        if watch.probe().isClear {
            let since = clearSince ?? time
            clearSince = since
            if time.timeIntervalSince(since) >= watch.settle {
                if let failure = watch.activate() {
                    stopWatching(as: .activationFailed, extra: ["error": String(failure.prefix(160))])
                } else {
                    let resume = self.resume
                    finish(as: .otherAudioStopped, releaseAfter: watch.releaseDelay)
                    resume?()
                }
                return
            }
        } else {
            clearSince = nil
        }
        scheduleCheck(hold: hold, after: watch.pollInterval)
    }

    /// End the fallback without giving up the time #1532 needs to receive a real end (especially for calls).
    private func stopWatching(as ending: Outcome, extra: [String: String] = [:]) {
        resume = nil
        clearSince = nil
        recordOutcome(ending, extra: extra)
    }

    private func finish(as ending: Outcome, extra: [String: String] = [:], releaseAfter delay: TimeInterval? = nil) {
        guard let release else { return }
        self.release = nil
        resume = nil
        clearSince = nil
        recordOutcome(ending, extra: extra)
        heldSince = nil
        if let delay, delay > 0 {
            // Keep the app awake while the resume it just asked for starts playing.
            schedule(delay) { release() }
        } else {
            release()
        }
    }

    private func recordOutcome(_ ending: Outcome, extra: [String: String]) {
        outcome = ending
        let heldSeconds = heldSince.map { now().timeIntervalSince($0) } ?? 0
        var fields = extra
        fields["outcome"] = ending.rawValue
        fields["heldMs"] = String(max(0, Int((heldSeconds * 1_000).rounded())))
        record(Self.eventKind, fields)
    }
}
