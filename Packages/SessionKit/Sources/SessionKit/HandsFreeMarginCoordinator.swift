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
    /// How long the background level is measured after the microphone opens.
    public static let calibration: TimeInterval = 0.5
    /// Speech needed for an interrupted Margin to be kept, marked cut short.
    public static let minimumSpeechToKeep: TimeInterval = 1
    /// Speech is this many dB above the background level, as `InterjectionSilenceDetector` uses.
    public static let speechMarginDB: Double = 8
    /// The learned speech threshold stays in this range. A background loud enough to reach the
    /// top still ends by press or by the cap.
    public static let lowestThresholdDB: Double = -50
    public static let highestThresholdDB: Double = -25
    /// At the end of the listening window, anything this far above the background counts as an
    /// attempt to talk: the recording is saved, not thrown away for a flag.
    public static let attemptMarginDB: Double = 4
    /// A closing tone that never reports finishing (a call cut it off) counts as finished after this.
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
/// once; a call keeps the Margin only with at least a second of speech; removed headphones save
/// and leave the source paused.
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
    private var lastLevel: (at: TimeInterval, isSpeech: Bool)?
    private var silenceSince: TimeInterval?
    private var warnedOfCap = false
    // How the current Margin closes, once decided.
    private var closingTone: HandsFreeTone?
    private var resumesAfter = true
    private var awaitingSave = false
    private var awaitingInterruptionEnd = false
    private var backgroundDB: Double?
    private var loudestDB: Double = -.infinity
    private var rejoiningSince: TimeInterval = 0

    /// - Parameter clock: seconds on a monotonic clock. Tests pass a fake one.
    public init(microphonePermission: HandsFreeMicrophonePermission = .undetermined, clock: @escaping () -> TimeInterval) {
        self.microphonePermission = microphonePermission
        self.clock = clock
    }

    private var isRecording: Bool { [.listening, .speaking, .trailingSilence].contains(phase) }

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
            commands += [.pauseSource, .playTone(.start)]
        case .startTone:
            // Pressed again before the microphone opened: nothing to keep, so a flag.
            commands += [.requestFlag] + close(tone: .flag, resume: true)
        case .listening:
            commands += flag()
        case .speaking, .trailingSilence:
            commands += finish(.press)
        case .saving where awaitingInterruptionEnd && !awaitingSave:
            // iOS doesn't always say a call ended. A press means the listener is back.
            awaitingInterruptionEnd = false
            resumesAfter = false
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
            phase = .listening
            recordingStartedAt = now
            commands.append(.beginRecording)
        case (.rejoining, _) where tone == closingTone:
            phase = .idle
            if resumesAfter { commands.append(.resumeSource) }
        default:
            break
        }
        return commands
    }

    /// One metering sample of the microphone, in dBFS (`AVAudioRecorder.averagePower`).
    public func level(_ decibels: Double) -> [HandsFreeMarginCommand] {
        let now = clock()
        guard isRecording else { return [] }
        if now - recordingStartedAt < HandsFreeMarginTimings.calibration {
            calibrationLevels.append(decibels)
            return timeouts(at: now)
        }
        let threshold = speechThresholdDB ?? learnThreshold()
        let isSpeech = decibels > threshold
        let lastSpeechAt = lastLevel.flatMap { $0.isSpeech ? $0.at : nil }
        if let lastSpeechAt { speechSeconds += now - lastSpeechAt }
        lastLevel = (now, isSpeech)
        loudestDB = max(loudestDB, decibels)
        if isSpeech {
            silenceSince = nil
            if phase != .speaking { phase = .speaking }
        } else if phase == .speaking {
            // The quiet began at the last sample that heard speech.
            phase = .trailingSilence
            silenceSince = lastSpeechAt ?? now
        }
        return timeouts(at: now)
    }

    /// Call often while recording (each metering tick does) so the window, silence and cap end on time.
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
            awaitingInterruptionEnd = true
            closingTone = .flag
            resumesAfter = true
            phase = .saving
            return due + [.requestFlag]
        case .listening, .speaking, .trailingSilence:
            awaitingInterruptionEnd = true
            if speechSeconds >= HandsFreeMarginTimings.minimumSpeechToKeep {
                return due + finish(.interruption)
            }
            closingTone = .flag
            resumesAfter = true
            phase = .saving
            return due + [.cancelRecording, .requestFlag]
        case .saving:
            awaitingInterruptionEnd = true
            return due
        case .rejoining:
            // The call cut the closing tone off; resume, if at all, when the call ends.
            closingTone = nil
            awaitingInterruptionEnd = true
            phase = .saving
            return due
        case .idle:
            return due
        }
    }

    /// The call ended. `shouldResume` is iOS's answer; the source resumes only when it says so.
    public func interruptionEnded(shouldResume: Bool) -> [HandsFreeMarginCommand] {
        guard phase == .saving, awaitingInterruptionEnd else { return [] }
        awaitingInterruptionEnd = false
        resumesAfter = resumesAfter && shouldResume
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
            phase = .idle
            return due + [.cancelRecording, .requestFlag]
        case .speaking, .trailingSilence:
            return due + finish(.headphonesRemoved)
        case .saving, .rejoining:
            closingTone = nil
            resumesAfter = false
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
        lastLevel = nil
        silenceSince = nil
        warnedOfCap = false
        closingTone = nil
        resumesAfter = true
        awaitingSave = false
        awaitingInterruptionEnd = false
        backgroundDB = nil
        loudestDB = -.infinity
    }

    /// The background level is the quietest calibration sample; speech sits a margin above it.
    private func learnThreshold() -> Double {
        let background = calibrationLevels.min() ?? HandsFreeMarginTimings.lowestThresholdDB - HandsFreeMarginTimings.speechMarginDB
        backgroundDB = background
        let threshold = min(HandsFreeMarginTimings.highestThresholdDB,
                            max(HandsFreeMarginTimings.lowestThresholdDB, background + HandsFreeMarginTimings.speechMarginDB))
        speechThresholdDB = threshold
        return threshold
    }

    private func timeouts(at now: TimeInterval) -> [HandsFreeMarginCommand] {
        if phase == .rejoining, now - rejoiningSince >= HandsFreeMarginTimings.toneTimeout {
            phase = .idle
            return resumesAfter ? [.resumeSource] : []
        }
        guard isRecording else { return [] }
        let elapsed = now - recordingStartedAt
        if phase == .listening, elapsed >= HandsFreeMarginTimings.listeningWindow {
            // Something rose above the background but never past the threshold: keep it
            // rather than lose words the threshold missed.
            if let backgroundDB, loudestDB > backgroundDB + HandsFreeMarginTimings.attemptMarginDB {
                return finish(.silence)
            }
            return flag()
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
        resumesAfter = reason != .headphonesRemoved
        return [.finishRecording(reason)]
    }

    private func close(tone: HandsFreeTone, resume: Bool) -> [HandsFreeMarginCommand] {
        closingTone = tone
        resumesAfter = resume
        phase = .saving
        return settle()
    }

    /// Plays the closing tone once nothing is pending; with no tone, resumes or stays paused.
    private func settle() -> [HandsFreeMarginCommand] {
        guard !awaitingSave, !awaitingInterruptionEnd else { return [] }
        if let tone = closingTone {
            phase = .rejoining
            rejoiningSince = clock()
            return [.playTone(tone)]
        }
        phase = .idle
        return resumesAfter ? [.resumeSource] : []
    }
}
