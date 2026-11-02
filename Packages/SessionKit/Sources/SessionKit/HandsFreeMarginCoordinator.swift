import Foundation

/// Every number hands-free capture uses, each one named so it can be tuned on the phone (D5, #775).
public enum HandsFreeMarginTimings {
    /// Time to start talking after the microphone opens. Silence for this long makes a flag.
    public static let listeningWindow: TimeInterval = 6
    /// Quiet after speech that ends the Margin.
    public static let trailingSilence: TimeInterval = 2.5
    /// The longest a hands-free Margin records.
    public static let cap: TimeInterval = 5 * 60
    /// When the soft "nearly at the cap" tick plays.
    public static let capWarning: TimeInterval = 4 * 60 + 30
    /// A second trigger this soon after the last one is a bounce (the same window as #148).
    public static let bounceWindow: TimeInterval = 0.5
    /// How long the background level is measured after the microphone opens. It is also how long a
    /// level a speech margin quieter must last, before speech is heard, to replace the first
    /// estimate: the listener may have started talking at once, so the first half-second was
    /// speech, not the room.
    public static let calibration: TimeInterval = 0.5
    /// Speech needed for an interrupted Margin to be kept, marked cut short.
    public static let minimumSpeechToKeep: TimeInterval = 1
    /// Speech is this many dB above the background level, as `InterjectionSilenceDetector` uses.
    public static let speechMarginDB: Double = 8
    /// The learned speech threshold stays in this range. A background loud enough to reach the
    /// top still ends by press or by the cap.
    public static let lowestThresholdDB: Double = -50
    public static let highestThresholdDB: Double = -25
    /// At a press, removed headphones or the end of the listening window, anything more than this
    /// far above the background counts as an attempt to talk: save the recording instead of a flag.
    public static let attemptMarginDB: Double = 4
    /// A tone that never reports finishing (a call cut it off, the player failed) counts as finished
    /// after this: the start tone opens the microphone, the closing tone resumes the source.
    public static let toneTimeout: TimeInterval = 3
}

/// Where a hands-free trigger came from. Every source follows the same rule.
public enum HandsFreeTriggerSource: String, Equatable, Sendable {
    case headphones
    case carPlay
    case lockScreen
    case actionButton
    case siri
    case watch
    case onScreen
}

public enum HandsFreeMicrophonePermission: Equatable, Sendable {
    case granted
    case denied
    case undetermined
}

/// The four bundled tones, plus the soft warning tick.
public enum HandsFreeTone: Equatable, Sendable {
    /// Rising two notes, before the microphone opens.
    case start
    /// Falling two notes, after the Margin is saved: "it's safe".
    case saved
    /// Falling double tick: nothing was said, a flag marks the spot.
    case flag
    /// Low tone: the microphone couldn't be used, a flag marks the spot.
    case couldNotRecord
    /// Soft tick at 4:30.
    case capWarning
}

public enum HandsFreeFinishReason: Equatable, Sendable {
    case silence
    case press
    case cap
    case interruption
    case headphonesRemoved

    /// A call or Siri took the microphone before the listener finished.
    public var isCutShort: Bool { self == .interruption }
}

/// What the app should do next. The coordinator never touches playback itself: the app carries
/// these out with its existing pause and resume and `SessionEngine`'s begin, finish and cancel.
/// `resumeSource` is the only resume: today `finishInterjection` and `cancelInterjection` resume
/// the source themselves, so the wiring slice needs them to save or discard without resuming.
public enum HandsFreeMarginCommand: Equatable, Sendable {
    /// Pause the source at the trigger, so the anchor is where the listener pressed.
    case pauseSource
    case playTone(HandsFreeTone)
    /// Open the microphone (`SessionEngine.beginInterjection`).
    case beginRecording
    /// Save the Margin (`SessionEngine.finishInterjection`). Report `saveCompleted()` when it's
    /// stored, or `saveFailed()`.
    case finishRecording(HandsFreeFinishReason)
    /// Discard the recording (`SessionEngine.cancelInterjection`).
    case cancelRecording
    /// Mark the anchor with a flag. Storing flags is a later slice.
    case requestFlag
    case resumeSource
}

/// Hands-free Margin capture: trigger, start tone, talk, silence, save tone, carry on (D5, #775).
///
/// A small state machine fed by a trigger, voice levels, tone and save completions, and
/// interruption and route events, on an injected clock. It returns commands and owns nothing:
/// no audio session, no recorder, no player. Saying nothing makes a flag; a press finishes at
/// once and keeps faint words as the silence timer does; a call keeps the Margin only with at
/// least a second of speech; removed headphones save what was said, faint words included, and
/// leave the source paused.
public final class HandsFreeMarginCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case startTone
        case listening
        case speaking
        case trailingSilence
        /// Waiting for the save to be stored, or for a call to end, before the closing tone.
        case saving
        /// The closing tone is playing; the source resumes after it.
        case rejoining
    }

    public private(set) var phase: Phase = .idle
    public private(set) var triggerSource: HandsFreeTriggerSource?
    /// The learned speech threshold for the current Margin, once calibrated.
    public private(set) var speechThresholdDB: Double?
    /// Seconds of speech heard in the current Margin.
    public private(set) var speechSeconds: TimeInterval = 0
    public var microphonePermission: HandsFreeMicrophonePermission

    private let clock: () -> TimeInterval
    private var lastTriggerAt: TimeInterval?
    private var recordingStartedAt: TimeInterval = 0
    private var calibrationLevels: [Double] = []
    // Every sample from the microphone opening until speech is heard, to replay under a new threshold.
    private var unspokenSamples: [(at: TimeInterval, decibels: Double)] = []
    // A run of samples, all quieter than the room estimate: where it began and its loudest sample.
    private var quieterRun: (since: TimeInterval, loudest: Double)?
    private var lastLevel: (at: TimeInterval, isSpeech: Bool)?
    private var silenceSince: TimeInterval?
    private var warnedOfCap = false
    // How the current Margin closes, once decided.
    private var closingTone: HandsFreeTone?
    private var resumeIntent = HandsFreeCaptureResume()
    private var awaitingSave = false
    private var backgroundDB: Double?
    private var loudestDB: Double = -.infinity
    private var rejoiningSince: TimeInterval = 0
    private var startToneSince: TimeInterval = 0

    /// - Parameter clock: seconds on a monotonic clock. Tests pass a fake one.
    public init(microphonePermission: HandsFreeMicrophonePermission = .undetermined, clock: @escaping () -> TimeInterval) {
        self.microphonePermission = microphonePermission
        self.clock = clock
    }

    private var isRecording: Bool { [.listening, .speaking, .trailingSilence].contains(phase) }

    /// Something rose above the background but never past the threshold: faint words, not silence.
    /// Ending the Margin keeps them rather than lose words the threshold missed.
    private var heardAnAttempt: Bool {
        guard let backgroundDB else { return false }
        return loudestDB > backgroundDB + HandsFreeMarginTimings.attemptMarginDB
    }

    // MARK: Inputs

    /// A press, a Siri request or a button. Starts a Margin when idle; finishes one in progress.
    public func trigger(from source: HandsFreeTriggerSource) -> [HandsFreeMarginCommand] {
        let now = clock()
        if let last = lastTriggerAt, now - last < HandsFreeMarginTimings.bounceWindow { return [] }
        var commands = timeouts(at: now)
        lastTriggerAt = now
        switch phase {
        case .idle:
            triggerSource = source
            reset()
            guard microphonePermission == .granted else {
                commands += [.pauseSource, .requestFlag]
                return commands + close(tone: .couldNotRecord, resume: true)
            }
            phase = .startTone
            startToneSince = now
            commands += [.pauseSource, .playTone(.start)]
        case .startTone:
            // Pressed again before the microphone opened: nothing to keep, so a flag.
            commands += [.requestFlag] + close(tone: .flag, resume: true)
        case .listening:
            // A press ends the Margin like the silence timer does: faint words the threshold missed
            // are kept, and only a Margin with nothing said is a flag.
            commands += heardAnAttempt ? finish(.press) : flag()
        case .speaking, .trailingSilence:
            commands += finish(.press)
        case .saving where resumeIntent.isWaitingForCallToEnd && !awaitingSave:
            // iOS doesn't always say a call ended. A press means the listener is back.
            resumeIntent.pressedAfterCallThatNeverEnded()
            commands += settle()
        case .saving, .rejoining:
            break
        }
        return commands
    }

    /// The app finished playing a tone.
    public func toneFinished(_ tone: HandsFreeTone) -> [HandsFreeMarginCommand] {
        let now = clock()
        var commands = timeouts(at: now)
        switch (phase, tone) {
        case (.startTone, .start):
            commands += openMicrophone(at: now)
        case (.rejoining, _) where tone == closingTone:
            phase = .idle
            if resumeIntent.resumesSource { commands.append(.resumeSource) }
        default:
            break
        }
        return commands
    }

    /// One metering sample of the microphone, in dBFS (`AVAudioRecorder.averagePower`).
    public func level(_ decibels: Double) -> [HandsFreeMarginCommand] {
        let now = clock()
        guard isRecording else { return [] }
        if phase == .listening { unspokenSamples.append((now, decibels)) }
        if now - recordingStartedAt < HandsFreeMarginTimings.calibration {
            calibrationLevels.append(decibels)
            return timeouts(at: now)
        }
        classify(decibels, at: now, threshold: speechThresholdDB ?? learnThreshold())
        loudestDB = max(loudestDB, decibels)
        relearnRoomIfQuieter(than: decibels, at: now)
        return timeouts(at: now)
    }

    /// Counts one sample as speech or quiet, and moves the phase between listening, speaking and
    /// trailing silence.
    private func classify(_ decibels: Double, at now: TimeInterval, threshold: Double) {
        let isSpeech = decibels > threshold
        let lastSpeechAt = lastLevel.flatMap { $0.isSpeech ? $0.at : nil }
        if let lastSpeechAt { speechSeconds += now - lastSpeechAt }
        lastLevel = (now, isSpeech)
        if isSpeech {
            silenceSince = nil
            if phase != .speaking { phase = .speaking }
        } else if phase == .speaking {
            // The quiet began at the last sample that heard speech.
            phase = .trailingSilence
            silenceSince = lastSpeechAt ?? now
        }
    }

    /// Call often while a Margin is in progress, including while a tone plays (each metering tick
    /// does while recording), so the tone timeouts, the window, silence and cap end on time.
    public func tick() -> [HandsFreeMarginCommand] {
        timeouts(at: clock())
    }

    /// The app stored the Margin. Its save tone plays now, unless a call is still going.
    public func saveCompleted() -> [HandsFreeMarginCommand] {
        guard phase == .saving, awaitingSave else { return [] }
        awaitingSave = false
        return settle()
    }

    /// The save threw. A flag keeps the spot, and the low tone says it didn't work.
    public func saveFailed() -> [HandsFreeMarginCommand] {
        guard phase == .saving, awaitingSave else { return [] }
        awaitingSave = false
        if closingTone != nil { closingTone = .couldNotRecord }
        return [.requestFlag] + settle()
    }

    /// Drops whatever is in progress and returns to idle, without commands. For the app to call
    /// when it gives up on a capture, such as on relaunch.
    public func abandon() {
        reset()
        phase = .idle
    }

    /// A call or Siri took the audio session.
    public func interruptionBegan() -> [HandsFreeMarginCommand] {
        let now = clock()
        let due = timeouts(at: now)
        if let last = lastLevel, last.isSpeech { speechSeconds += now - last.at; lastLevel = (now, true) }
        switch phase {
        case .startTone:
            resumeIntent.callBegan()
            closingTone = .flag
            resumeIntent.closing(resume: true)
            phase = .saving
            return due + [.requestFlag]
        case .listening, .speaking, .trailingSilence:
            resumeIntent.callBegan()
            if speechSeconds >= HandsFreeMarginTimings.minimumSpeechToKeep {
                return due + finish(.interruption)
            }
            closingTone = .flag
            resumeIntent.closing(resume: true)
            phase = .saving
            return due + [.cancelRecording, .requestFlag]
        case .saving:
            resumeIntent.callBegan()
            return due
        case .rejoining:
            // The call cut the closing tone off; resume, if at all, when the call ends.
            closingTone = nil
            resumeIntent.callBegan()
            phase = .saving
            return due
        case .idle:
            return due
        }
    }

    /// The call ended. `end` is iOS's answer; the source resumes only when it says audio may start again.
    public func interruptionEnded(_ end: InterruptionEnd) -> [HandsFreeMarginCommand] {
        guard phase == .saving, resumeIntent.callEnded(end) else { return [] }
        return settle()
    }

    /// The output route changed. Removed headphones save what was said and leave the source paused,
    /// with no tone, so nothing plays from the phone speaker.
    public func headphonesRemoved() -> [HandsFreeMarginCommand] {
        let due = timeouts(at: clock())
        switch phase {
        case .startTone:
            phase = .idle
            return due + [.requestFlag]
        case .listening:
            if heardAnAttempt { return due + finish(.headphonesRemoved) }
            phase = .idle
            return due + [.cancelRecording, .requestFlag]
        case .speaking, .trailingSilence:
            return due + finish(.headphonesRemoved)
        case .saving, .rejoining:
            closingTone = nil
            resumeIntent.headphonesRemoved()
            if phase == .rejoining { phase = .idle }
            return due
        case .idle:
            return due
        }
    }

    // MARK: Transitions

    private func reset() {
        speechThresholdDB = nil
        speechSeconds = 0
        calibrationLevels = []
        unspokenSamples = []
        quieterRun = nil
        lastLevel = nil
        silenceSince = nil
        warnedOfCap = false
        closingTone = nil
        resumeIntent.reset()
        awaitingSave = false
        backgroundDB = nil
        loudestDB = -.infinity
    }

    /// The background level is the quietest calibration sample; speech sits a margin above it.
    private func learnThreshold() -> Double {
        setBackground(calibrationLevels.min() ?? HandsFreeMarginTimings.lowestThresholdDB - HandsFreeMarginTimings.speechMarginDB)
    }

    /// A listener who talks the instant the tone ends fills the calibration with speech, so the
    /// first estimate of the room is too loud and the threshold too high. Until speech is heard,
    /// a level that stays a speech margin below the estimate for the calibration time shows the
    /// room really is that quiet, and what was taken for the room would now count as speech:
    /// learn from it and replay the samples so far under the new threshold, so the words already
    /// spoken count. One quiet sample, a short dip or ordinary drift never does this, or steady
    /// noise would start to read as speech. Once speaking, the room is settled.
    private func relearnRoomIfQuieter(than decibels: Double, at now: TimeInterval) {
        guard phase == .listening, let backgroundDB, decibels < backgroundDB - HandsFreeMarginTimings.speechMarginDB else {
            quieterRun = nil
            if phase != .listening { unspokenSamples = [] }
            return
        }
        let run = (since: quieterRun?.since ?? now, loudest: max(quieterRun?.loudest ?? decibels, decibels))
        quieterRun = run
        guard now - run.since >= HandsFreeMarginTimings.calibration else { return }
        quieterRun = nil
        let threshold = setBackground(run.loudest)
        lastLevel = nil
        speechSeconds = 0
        silenceSince = nil
        for sample in unspokenSamples { classify(sample.decibels, at: sample.at, threshold: threshold) }
        if phase != .listening { unspokenSamples = [] }
    }

    private func setBackground(_ background: Double) -> Double {
        backgroundDB = background
        let threshold = min(HandsFreeMarginTimings.highestThresholdDB,
                            max(HandsFreeMarginTimings.lowestThresholdDB, background + HandsFreeMarginTimings.speechMarginDB))
        speechThresholdDB = threshold
        return threshold
    }

    /// The start tone is over, reported or timed out: the microphone opens and the window starts.
    private func openMicrophone(at now: TimeInterval) -> [HandsFreeMarginCommand] {
        phase = .listening
        recordingStartedAt = now
        return [.beginRecording]
    }

    private func timeouts(at now: TimeInterval) -> [HandsFreeMarginCommand] {
        if phase == .startTone, now - startToneSince >= HandsFreeMarginTimings.toneTimeout {
            // The tone's end was never reported. Carry on as if it had, so the source isn't left
            // paused with the microphone closed; a late report then finds the phase moved on.
            return openMicrophone(at: now)
        }
        if phase == .rejoining, now - rejoiningSince >= HandsFreeMarginTimings.toneTimeout {
            phase = .idle
            return resumeIntent.resumesSource ? [.resumeSource] : []
        }
        guard isRecording else { return [] }
        let elapsed = now - recordingStartedAt
        if phase == .listening, elapsed >= HandsFreeMarginTimings.listeningWindow {
            return heardAnAttempt ? finish(.silence) : flag()
        }
        if phase == .trailingSilence, let since = silenceSince, now - since >= HandsFreeMarginTimings.trailingSilence {
            return finish(.silence)
        }
        if elapsed >= HandsFreeMarginTimings.cap {
            return finish(.cap)
        }
        if elapsed >= HandsFreeMarginTimings.capWarning, !warnedOfCap {
            warnedOfCap = true
            return [.playTone(.capWarning)]
        }
        return []
    }

    /// Nothing was said: drop the recording and flag the anchor.
    private func flag() -> [HandsFreeMarginCommand] {
        [.cancelRecording, .requestFlag] + close(tone: .flag, resume: true)
    }

    /// Save what was said. The closing tone waits for `saveCompleted()`, so it means "it's safe".
    private func finish(_ reason: HandsFreeFinishReason) -> [HandsFreeMarginCommand] {
        phase = .saving
        awaitingSave = true
        closingTone = reason == .headphonesRemoved ? nil : .saved
        resumeIntent.closing(resume: reason != .headphonesRemoved)
        return [.finishRecording(reason)]
    }

    private func close(tone: HandsFreeTone, resume: Bool) -> [HandsFreeMarginCommand] {
        closingTone = tone
        resumeIntent.closing(resume: resume)
        phase = .saving
        return settle()
    }

    /// Plays the closing tone once nothing is pending; with no tone, resumes or stays paused.
    private func settle() -> [HandsFreeMarginCommand] {
        guard !awaitingSave, !resumeIntent.isWaitingForCallToEnd else { return [] }
        if let tone = closingTone {
            phase = .rejoining
            rejoiningSince = clock()
            return [.playTone(tone)]
        }
        phase = .idle
        return resumeIntent.resumesSource ? [.resumeSource] : []
    }
}
