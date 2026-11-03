import Foundation

/// What the pinned Margin card on the Now screen says (#3220). One card serves a review of new Margins, "Play this
/// moment" and a friend's Margin that plays by itself as the episode reaches it, so the listener sees one playback
/// experience. The card sits in a fixed slot above the title; this type holds its words so they can be tested on the
/// host and the view only draws them.
public struct PinnedMarginCard: Equatable, Sendable {
    /// Whose Margin the card is about.
    public enum Subject: Equatable, Sendable {
        case yours
        /// A friend's Margin, with the name on their layer when it has one.
        case friend(String?)

        /// "Your Margin" or "Cole's Margin".
        public var possessive: String {
            switch self {
            case .yours: "Your Margin"
            case .friend(let name): name.map { "\($0)'s Margin" } ?? "A friend's Margin"
            }
        }

        /// "Cole is speaking" needs a name for the one who speaks.
        public var speaker: String {
            switch self {
            case .yours: "You are"
            case .friend(let name): name.map { "\($0) is" } ?? "A friend is"
            }
        }
    }

    public enum Stage: Equatable, Sendable {
        /// The voice is sounding.
        case speaking
        /// The listener paused the voice.
        case voicePaused
        /// The voice was asked for and is not sounding yet.
        case loading
        /// The voice could not play.
        case failed
        /// A lead-in is under way: the Margin plays when the episode reaches it (or when the listener says so).
        case comingUp(msRemaining: Int?)
        /// A Margin is here and waits for the listener's tap (tone-only or jumped to).
        case waitingForTap
        /// Between Margins of a friend's listen: the next one is `msRemaining` ahead, nil when that is not known.
        case upNext(msRemaining: Int?)
    }

    public let subject: Subject
    public let stage: Stage
    /// Which Margin of how many, "1 of 3". Nil when the card is not counting (a single Margin of your own).
    public let position: String?

    public init(subject: Subject, stage: Stage, position: String? = nil) {
        self.subject = subject
        self.stage = stage
        self.position = position
    }

    public static func position(_ index: Int, of count: Int) -> String? {
        count > 1 ? "\(index) of \(count)" : nil
    }

    /// The card's one-line headline: "Cole is speaking", "Cole's Margin in 0:08".
    public var headline: String {
        switch stage {
        case .speaking: "\(subject.speaker) speaking"
        case .voicePaused: "\(subject.possessive) is paused"
        case .loading: "Loading \(subject.possessive)…"
        case .failed: "\(subject.possessive) could not play"
        case .comingUp(let ms):
            ms.map { "\(subject.possessive) in \(Self.countdown($0))" } ?? "Getting to \(subject.possessive)"
        case .waitingForTap: "\(subject.possessive) is here"
        case .upNext(let ms):
            ms.map { "Next: \(subject.possessive) in \(Self.countdown($0))" } ?? "Next: \(subject.possessive)"
        }
    }

    /// The second line, which says what the episode is doing, so the card keeps one shape in every stage.
    public var detail: String {
        switch stage {
        case .speaking: "The episode is paused while this plays."
        case .voicePaused: "The episode stays paused until this is done."
        case .loading: "Hold on, this is getting ready."
        case .failed: "The episode carries on without it."
        case .comingUp: "It plays by itself when the episode gets there."
        case .waitingForTap: "The episode is paused. Tap Listen to hear it."
        case .upNext: "It plays by itself when the episode gets there."
        }
    }

    /// Minutes and seconds, rounded up so the card never promises an early arrival.
    public static func countdown(_ ms: Int) -> String {
        let ms = max(0, ms)
        let seconds = ms / 1_000 + (ms % 1_000 == 0 ? 0 : 1)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// "Next Margin" (#3220, #460): the first press goes to the next Margin's lead-in, the second goes straight to the
/// Margin. The rule is on position only; the app does the seeking and the playing.
public enum NextMarginPress: Equatable, Sendable {
    /// Seek the episode to where the next Margin's lead-in starts. A friend's voice that is sounding stops first.
    case seekToLeadIn(mediaTimeMs: Int)
    /// Play the Margin now, skipping what is left of its lead-in.
    case playMarginNow
    /// A review's Margin voice is sounding: end it, and the review goes on to the next Margin's lead-in.
    case skipVoice
    /// There is no later Margin to go to.
    case unavailable

    public enum Context: Equatable, Sendable {
        /// A review or "Play this moment" is waiting at its lead-in.
        case momentLeadIn(isReview: Bool)
        /// A review's or moment's voice is sounding.
        case momentVoice(isReview: Bool, isLastMargin: Bool)
        /// No moment is running: the episode plays and a friend's Margins come as it reaches them. `positionMs` is the
        /// playhead, `nextMarginMs` the next friend's Margin after it, either nil when not known.
        case sharedPlayback(positionMs: Int?, nextMarginMs: Int?)
    }

    public static func press(_ context: Context) -> NextMarginPress {
        switch context {
        case .momentLeadIn(let isReview):
            return isReview ? .playMarginNow : .unavailable
        case .momentVoice(let isReview, let isLastMargin):
            return isReview && !isLastMargin ? .skipVoice : .unavailable
        case .sharedPlayback(let position, let next):
            guard let next else { return .unavailable }
            let leadIn = MarginMomentSequence.leadInStartMediaTimeMs(
                forTarget: MarginMomentAnchor(marginId: "next", mediaTimeMs: next),
                leadInMs: MarginMomentSequence.reviewLeadInMs
            )
            // Already inside the lead-in: this press is the second one. This also covers a voice that is sounding right
            // before a close Margin, so the press never seeks backwards into the Margin that is playing.
            if let position, position >= leadIn { return .playMarginNow }
            return .seekToLeadIn(mediaTimeMs: max(0, leadIn))
        }
    }

    /// The first Margin after the playhead, from the positions of a friend's Margins on the item.
    public static func nextMarginMs(after positionMs: Int?, among marginsMs: [Int]) -> Int? {
        guard let positionMs else { return marginsMs.min() }
        return marginsMs.filter { $0 > positionMs }.min()
    }
}
