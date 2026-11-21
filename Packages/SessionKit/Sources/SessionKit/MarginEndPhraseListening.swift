import Foundation

/// What the recording screen says about listening for the end phrase (#3940, PR 3 of the Design).
public enum MarginEndPhraseHint: Sendable, Equatable {
    /// Not listening, or listening has stopped: the screen is exactly as it was before this feature.
    case none
    /// Listening: "Say "stop margin" to finish".
    case listening
    /// The phrase was heard as the last words and is being confirmed: "Finishing…".
    case finishing
}

/// Where Speech Recognition stands for the app, without importing Speech (the host tests can't).
public enum SpeechRecognitionAccessState: Sendable, Equatable {
    case authorized, notDetermined, denied, restricted
}

/// Whether a Margin that is about to record listens for the end phrase. Pure: the app reads the settings, the
/// device and the clock, and this says yes or why not. A "no" is not an error: the recording screen is then as it
/// was, and nothing is asked or shown (a prompt while the microphone is live is the #2966 trap).
public enum MarginEndPhraseAvailability: Sendable, Equatable {
    case available
    case off(Reason)

    /// A short stable key for Diagnostics, never listener words.
    public enum Reason: String, Sendable, Equatable {
        case switchedOff = "toggle_off"
        case languageNotEnglish = "language_not_english"
        /// Not asked yet: the first Margin's transcription asks, and the next Margin listens (Design, `first-run`).
        case speechNotAsked = "speech_not_asked"
        case speechDenied = "speech_denied"
        case tooHot = "thermal_serious"
    }

    /// The Settings toggle's storage key; on until the listener turns it off.
    public static let storageKey = "marginEndPhrase"

    public static func isSwitchedOn(stored: Bool?) -> Bool { stored ?? true }

    /// `languageCode` is the device language's code ("en" for any English region). The phrases are English, so any
    /// other language is off. Low Power Mode does not turn listening off: the phrase is the only hands-free end, and
    /// a car is where Low Power Mode is common; only a thermal state of serious or worse does.
    public static func decide(
        isSwitchedOn: Bool,
        speech: SpeechRecognitionAccessState,
        languageCode: String?,
        thermalIsSeriousOrWorse: Bool
    ) -> MarginEndPhraseAvailability {
        guard isSwitchedOn else { return .off(.switchedOff) }
        guard languageCode?.lowercased() == "en" else { return .off(.languageNotEnglish) }
        switch speech {
        case .authorized: break
        case .notDetermined: return .off(.speechNotAsked)
        case .denied, .restricted: return .off(.speechDenied)
        }
        guard !thermalIsSeriousOrWorse else { return .off(.tooHot) }
        return .available
    }
}

/// Runs the phrase rule on the live recogniser's results for one Margin and says when to end it (#3940).
///
/// Its clock is the time since the recogniser started, minus `deliveryLagMs`: results arrive after the words are
/// spoken, so a clock that ran ahead of them could confirm "stop margin" a moment before the next word of "stop
/// margin notes" is delivered. Waiting that extra second costs a listener who says the phrase 2 s instead of 1 s;
/// ending on a sentence they were still saying costs their words.
///
/// It never ends a Margin without the phrase: no word, any amount of quiet, gives `.unchanged`. `.end` comes at most
/// once; a second phrase, or the same one twice, is not a second end.
public struct MarginEndPhraseDecider: Sendable {
    public static let deliveryLagMs = 1_000

    public enum Step: Sendable, Equatable {
        case unchanged
        /// The phrase went away (a word came within the confirming second, or the guess was revised).
        case listening
        case finishing
        case end
    }

    private var window = MarginEndPhraseWindow()
    private var confirming = false
    private var ended = false

    public init() {}

    /// A result from the recogniser, `sinceStartMs` after it started. `resultStartMs` is where the result starts in the
    /// recogniser's audio clock: with it, a guess revised to nothing (an empty `batch`) takes back what it said for that
    /// stretch, so a withdrawn "stop margin" can't be confirmed.
    public mutating func receive(
        _ batch: [MarginEndPhraseWord], isFinal: Bool, sinceStartMs: Int, resultStartMs: Int? = nil
    ) -> Step {
        step(window.advance(
            audioNowMs: sinceStartMs - Self.deliveryLagMs, hearing: batch, isFinal: isFinal, resultStartMs: resultStartMs
        ))
    }

    /// Time passing with no result, `sinceStartMs` after the recogniser started.
    public mutating func tick(sinceStartMs: Int) -> Step {
        step(window.advance(audioNowMs: sinceStartMs - Self.deliveryLagMs))
    }

    private mutating func step(_ outcome: MarginEndPhrase.Outcome) -> Step {
        guard !ended else { return .unchanged }
        switch outcome {
        case .end:
            ended = true
            return .end
        case .confirming:
            guard !confirming else { return .unchanged }
            confirming = true
            return .finishing
        case .none:
            guard confirming else { return .unchanged }
            confirming = false
            return .listening
        }
    }
}
