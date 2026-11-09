import Foundation

/// How a shared Margin is put to the listener when playback reaches it, or when they jump to it (#3059).
///
/// The owner's call (2026-10-31): a friend's Margins play in place by default. With auto-play off the listener
/// hears only a tone where each Margin sits, and the episode keeps playing; one tap on the card hears the Margin.
/// A pure value: it decides what the prompt does and keeps no state. The model acts on it.
public struct SharedMarginPromptStyle: Sendable, Equatable {
    /// How the listener came to the Margin.
    public enum Arrival: Sendable, Equatable {
        /// Playback reached it.
        case crossed
        /// The listener went to it themselves (the Margins tab, the Timeline): the episode waits at the Margin.
        case jumpedTo
    }

    /// How long a tone-only card waits for a tap before it goes away and the next Margin can be offered.
    public static let toneOnlyCardMs = 12_000
    /// The pause between the tone and the voice when the Margin plays on its own.
    public static let autoPlayDelayMs = 420

    /// The episode pauses for the prompt, and comes back after it is answered.
    public let pausesSource: Bool
    /// The Margin's voice starts by itself after this long. Nil when the listener chooses.
    public let autoPlayAfterMs: Int?
    /// The card goes away unanswered after this long. Nil when it waits for an answer.
    public let expiresAfterMs: Int?

    /// A tone and a card the listener may ignore while the episode plays on. With no expiry (assistive technology) it
    /// is the one card a newly crossed Margin may replace, so it can't hide every later Margin (#3720).
    public var isToneOnly: Bool { !pausesSource && autoPlayAfterMs == nil }

    /// A layer with no reveal mode set is not auto-play (as before: only `.guided` plays by itself).
    ///
    /// With VoiceOver or Switch Control running, finding and activating the card takes longer than 12 seconds, so the
    /// tone-only card waits for an answer, as the card for a Margin the listener jumped to does (#3720). For a listener
    /// touching the card or on it with focus, the app holds the timer (`FeedbackBannerPolicy.timerIsHeld`).
    public static func style(
        revealMode: ImportedCommentaryRevealMode?,
        arrival: Arrival,
        assistiveTechnologyRunning: Bool = false
    ) -> SharedMarginPromptStyle {
        if revealMode == .guided {
            return SharedMarginPromptStyle(pausesSource: true, autoPlayAfterMs: autoPlayDelayMs, expiresAfterMs: nil)
        }
        switch arrival {
        case .crossed:
            return SharedMarginPromptStyle(
                pausesSource: false, autoPlayAfterMs: nil,
                expiresAfterMs: assistiveTechnologyRunning ? nil : toneOnlyCardMs)
        case .jumpedTo:
            return SharedMarginPromptStyle(pausesSource: true, autoPlayAfterMs: nil, expiresAfterMs: nil)
        }
    }
}
