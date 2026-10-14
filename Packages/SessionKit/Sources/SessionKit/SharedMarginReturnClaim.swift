/// Who has promised that the source comes back after a shared Margin, and whether that promise is
/// still owed (#997). One value replaces the two stored "should the source resume" booleans the app
/// model kept for this (`sourcePausedForImportedCommentaryPrompt` and
/// `sourceShouldResumeAfterImportedCommentary`).
///
/// Two different things can hold the promise:
/// - **the prompt**: the Margin was offered (a card is up, or was) while the source was playing, and
///   the offer paused it. Answering the offer, by listening or by dismissing, owes the source back.
/// - **the voice**: the Margin's voice is playing and the source was playing when it was started (or
///   the voice replaced a voice that already held the promise). The voice ending, or Return, owes it.
///
/// They are held independently of the card on screen and of the voice phase. A card cleared by
/// opening another session does not release the prompt's part, and a re-entrant widget Listen between
/// the two halves of a jump can leave both held, so the combined case stays (the transition table in
/// `docs/gate1-playback-transition-table.md`, section "Shared Margin return claim").
///
/// The model calls these at the same points, in the same order, as the booleans were read and
/// written. They do not merge steps: the listen path is capture, then pause and stop (which can
/// re-enter), then restore, and each of those is its own call so a nested transition sees the value
/// the staged sequence had at that moment. Every decision is made from the value before the call and
/// the value is changed before the model acts on the decision, so a repeated completion cannot
/// resume the source twice.
public enum SharedMarginReturnClaim: Equatable, Sendable {
    case none
    case prompt
    case voice
    case promptAndVoice

    /// Nothing is owed.
    public init() { self = .none }

    public var heldByPrompt: Bool {
        self == .prompt || self == .promptAndVoice
    }

    public var heldByVoice: Bool {
        self == .voice || self == .promptAndVoice
    }

    /// A prompt was presented. The prompt's part is set to whether the source was playing (and so is
    /// now paused by the offer), replacing whatever an earlier prompt left. The voice's part stays.
    public mutating func promptShown(sourceWasPlaying: Bool) {
        self = Self.make(prompt: sourceWasPlaying, voice: heldByVoice)
    }

    /// The listener dismissed the card (or it timed out unanswered). Returns whether the offer owes the
    /// source back; the prompt's part is released either way. The voice's part stays.
    public mutating func promptDismissed() -> Bool {
        let owed = heldByPrompt
        self = Self.make(prompt: false, voice: heldByVoice)
        return owed
    }

    /// Listen was asked for, before anything is paused or stopped. Returns whether the source should
    /// come back once this voice ends: the prompt owed it, or the source is playing now, or a voice
    /// already playing held it. Releases the prompt's part. Call `voiceStopped()` for the voice being
    /// replaced next, then `voiceStarted(returnToSource:)` with this result.
    public mutating func listenRequested(sourceIsPlaying: Bool, voiceIsPlaying: Bool) -> Bool {
        let owed = heldByPrompt || sourceIsPlaying || (voiceIsPlaying && heldByVoice)
        self = Self.make(prompt: false, voice: heldByVoice)
        return owed
    }

    /// A voice starts, or a retry starts a fresh attempt. The voice's part is set to `returnToSource`;
    /// the prompt's part stays.
    public mutating func voiceStarted(returnToSource: Bool) {
        self = Self.make(prompt: heldByPrompt, voice: returnToSource)
    }

    /// The voice stopped for any reason, including a stop that replaces it and a stop that must not
    /// return the source (a new session, a different item, a failure). The voice's part is released;
    /// the prompt's part stays.
    public mutating func voiceStopped() {
        self = Self.make(prompt: heldByPrompt, voice: false)
    }

    /// Whether ending the voice should bring the source back. Reads the value as it is before the voice
    /// is stopped; the stop (`voiceStopped()`) is a separate call.
    public func returnsSourceWhenVoiceEnds(resumeSource: Bool) -> Bool {
        resumeSource && heldByVoice
    }

    private static func make(prompt: Bool, voice: Bool) -> SharedMarginReturnClaim {
        switch (prompt, voice) {
        case (false, false): return .none
        case (true, false): return .prompt
        case (false, true): return .voice
        case (true, true): return .promptAndVoice
        }
    }
}
