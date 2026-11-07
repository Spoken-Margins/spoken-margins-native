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
            case .friend(let name): SharedPacketArrival.senderName(name).map { "\($0)'s Margin" } ?? "A friend's Margin"
            }
        }

        /// "Cole wrote this" (the web page's words for a written Margin).
        public var writer: String {
            switch self {
            case .yours: "You"
            case .friend(let name): name ?? "A friend"
            }
        }

        /// "Cole's words": whose words the iPhone's voice is reading.
        public var words: String {
            switch self {
            case .yours: "your words"
            case .friend(let name): name.map { "\($0)'s words" } ?? "your friend's words"
            }
        }

        /// "Cole's first Margin" / "A friend's next Margin": the words for the Margin ahead (#3247). Only a friend's.
        public func possessive(ordinal: String) -> String {
            switch self {
            case .yours: "Your \(ordinal) Margin"
            case .friend(let name): SharedPacketArrival.senderName(name).map { "\($0)'s \(ordinal) Margin" } ?? "A friend's \(ordinal) Margin"
            }
        }

        /// "Cole" or "your friend", for "Skip to just before Cole".
        public var nameOrYourFriend: String {
            switch self {
            case .yours: "you"
            case .friend(let name): SharedPacketArrival.senderName(name) ?? "your friend"
            }
        }

        /// "Cole is speaking" needs a name for the one who speaks.
        public var speaker: String {
            switch self {
            case .yours: "You are"
            case .friend(let name): SharedPacketArrival.senderName(name).map { "\($0) is" } ?? "A friend is"
            }
        }
    }

    public enum Stage: Equatable, Sendable {
        /// The voice is sounding.
        case speaking
        /// A friend's written Margin is being read aloud by the iPhone's voice, so the card never says the friend is speaking.
        case reading
        /// The listener paused the voice.
        case voicePaused
        /// The voice was asked for and is not sounding yet.
        case loading
        /// The voice could not play. `canMoveOn`: Next Margin has somewhere to go.
        case failed(canMoveOn: Bool)
        /// A lead-in is under way: the Margin plays when the episode reaches it (or when the listener says so).
        case comingUp(msRemaining: Int?)
        /// A Margin is here and waits for the listener's tap (tone-only or jumped to).
        case waitingForTap
        /// Between Margins of a friend's listen: the next one is `msRemaining` ahead, nil when that is not known.
        case upNext(msRemaining: Int?, arrival: Arrival)
        /// A friend just saved a Margin of their own: it can be sent with Share (`answerSaved`). `atMs` is its place in the
        /// episode, nil on text; `sentTo` is who it would go to.
        case answerSaved(atMs: Int?, sentTo: String)
        /// The last of a friend's Margins has played and none is ahead (`friendsLast`). `senders` is how many people's
        /// Margins the item holds; the subject names the one when there is one.
        case lastMargin(senders: Int)
    }

    /// What happens when the episode gets to the next Margin.
    public enum Arrival: Equatable, Sendable {
        /// Auto-play is on and the Margin is new to this run of the episode: it plays by itself.
        case playsByItself
        /// Auto-play is off: a tone sounds and the listener taps Listen.
        case toneThenTap
        /// The Margin was announced already (a finished review, or heard before the listener scrubbed back), so
        /// reaching it plays nothing. Next Margin plays it.
        case onRequest
        /// The Margin's layer is Fresh: the episode never offers it. Next Margin plays it, with no lead-in to wait through.
        case waitsForYou

        /// What happens when the episode reaches a Margin, from the same rules the offer uses: a Fresh layer is never
        /// offered, an announced Margin is not offered again, and otherwise the layer's own reveal mode decides
        /// (`SharedMarginPromptStyle`). Per Margin, never per item: layers on one episode can differ.
        public static func forMargin(announced: Bool, revealMode: ImportedCommentaryRevealMode?) -> Arrival {
            if revealMode == .fresh { return .waitsForYou }
            if announced { return .onRequest }
            let style = SharedMarginPromptStyle.style(revealMode: revealMode, arrival: .crossed)
            return style.autoPlayAfterMs != nil ? .playsByItself : .toneThenTap
        }
    }

    public let subject: Subject
    public let stage: Stage
    /// Which Margin of how many, "1 of 3". Nil when the card is not counting (a single Margin of your own).
    public let position: String?
    /// How far through the voice, "0:14 of 0:41", while it plays. Nil when the voice has no readable clock yet.
    public let voiceTime: String?
    /// The Margin ahead is the first one from its sender (number 1 in that sender's file), so "first" is true. Only
    /// the between-Margins friend card reads it.
    public let isFirstFromSender: Bool

    public init(subject: Subject, stage: Stage, position: String? = nil, voiceTime: String? = nil, isFirstFromSender: Bool = false) {
        self.subject = subject
        self.stage = stage
        self.position = position
        self.voiceTime = voiceTime
        self.isFirstFromSender = isFirstFromSender
    }

    /// "0:14 of 0:41" from a voice clock, nil when the duration or the time is not a real number yet.
    public static func voiceTime(current: Double, duration: Double) -> String? {
        guard current.isFinite, duration.isFinite, duration > 0 else { return nil }
        let now = min(max(0, current), duration)
        return "\(clock(Int(now.rounded(.down)))) of \(clock(Int(duration.rounded(.up))))"
    }

    private static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    public static func position(_ index: Int, of count: Int) -> String? {
        count > 1 ? "\(index) of \(count)" : nil
    }

    /// The card's one-line headline: "Cole is speaking", "Cole's Margin in 0:08".
    public var headline: String {
        switch stage {
        case .speaking: "\(subject.speaker) speaking"
        case .reading: "\(subject.writer) wrote this"
        case .voicePaused: "\(subject.possessive) is paused"
        case .loading: "Loading \(subject.possessive)…"
        case .failed: "\(subject.possessive) could not play"
        case .comingUp(let ms):
            ms.map { "\(subject.possessive) in \(Self.countdown($0))" } ?? "Getting to \(subject.possessive)"
        case .waitingForTap: "\(subject.possessive) is here"
        case .upNext(let ms, _): upNextHeadline(msRemaining: ms)
        case .answerSaved(let atMs, _):
            "Your Margin is saved" + (atMs.map { " at \(SharedMarginReview.ReplyContext.clock($0))" } ?? "")
        case .lastMargin(let senders):
            senders > 1 ? "That was the last of your friends' Margins" : "That was \(subject.nameOrYourFriend)'s last Margin"
        }
    }

    private func upNextHeadline(msRemaining ms: Int?) -> String {
        guard case .friend = subject else {
            return ms.map { "Next: \(subject.possessive) in \(Self.countdown($0))" } ?? "Next: \(subject.possessive)"
        }
        // "first" only when it is true; later ones are "next" (#3247).
        let margin = subject.possessive(ordinal: isFirstFromSender ? "first" : "next")
        return ms.map { "\(margin) \(Self.friendCountdown($0))" } ?? "\(margin) is ahead"
    }

    /// The second line, which says what the episode is doing, so the card keeps one shape in every stage.
    public var detail: String {
        switch stage {
        case .speaking: voiceTime.map { "\($0) · The episode is paused." } ?? "The episode is paused while this plays."
        case .reading: voiceTime.map { "\($0) · Your phone's voice is reading \(subject.words)." } ?? "Your phone's voice is reading \(subject.words)."
        case .voicePaused: voiceTime.map { "\($0) · The episode stays paused." } ?? "The episode stays paused until this is done."
        case .loading: "Hold on, this is getting ready."
        case .failed(let canMoveOn):
            canMoveOn ? "The episode is paused. Tap Retry, or Next Margin to move on." : "The episode is paused. Tap Retry, or Return to Source."
        case .comingUp: "It plays by itself when the episode gets there."
        case .waitingForTap: "The episode is paused. Tap Listen to hear it."
        case .answerSaved(_, let sentTo): "To send it to \(sentTo), tap Share below. You pick which of your Margins go."
        case .lastMargin(let senders): "To answer \(senders > 1 ? "your friends" : subject.nameOrYourFriend), add a Margin of your own."
        case .upNext(_, let arrival):
            switch arrival {
            case .playsByItself: "It plays by itself when the episode gets there."
            case .toneThenTap: "You will hear a tone. Tap Listen to hear it."
            case .onRequest: "You have heard this one. Tap Next Margin to hear it again."
            case .waitsForYou: "This one waits for you. Tap Next Margin to hear it."
            }
        }
    }

    /// "in 11 min" for a friend's Margin ahead, in whole minutes rounded up so it never promises an early arrival;
    /// "in under 1 min" below a minute, then "in 15 sec" from the lead-in on (the last `reviewLeadInMs`). "11:28" read as a
    /// clock time. It counts the episode's own time, so it runs long at a speed above 1x. Never "in 0 min" (#3247).
    public static func friendCountdown(_ ms: Int) -> String {
        let ms = max(0, ms)
        if ms <= MarginMomentSequence.reviewLeadInMs {
            return "in \(max(1, (ms + 999) / 1_000)) sec"
        }
        if ms < 60_000 { return "in under 1 min" }
        return "in \((ms + 59_999) / 60_000) min"
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
        case sharedPlayback(positionMs: Int?, nextMarginMs: Int?, arrival: PinnedMarginCard.Arrival)
    }

    public static func press(_ context: Context) -> NextMarginPress {
        switch context {
        case .momentLeadIn(let isReview):
            return isReview ? .playMarginNow : .unavailable
        case .momentVoice(let isReview, let isLastMargin):
            return isReview && !isLastMargin ? .skipVoice : .unavailable
        case .sharedPlayback(let position, let next, let arrival):
            guard let next else { return .unavailable }
            // A Fresh layer's Margin is never offered, so a lead-in would end in silence: go straight to it.
            if arrival == .waitsForYou { return .playMarginNow }
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

/// The words on the card's skip button between a friend's Margins (#3247). They come from the press the button will
/// make, so the label and the tap cannot disagree; everything else keeps "Next Margin".
public struct NextMarginWords: Equatable, Sendable {
    public let title: String
    /// What the tap does, for VoiceOver.
    public let hint: String?

    public init(press: NextMarginPress, subject: PinnedMarginCard.Subject) {
        guard case .friend = subject else { title = "Next Margin"; hint = nil; return }
        let name = subject.nameOrYourFriend
        switch press {
        case .seekToLeadIn:
            title = "Skip to just before \(name)"
            hint = "Moves the episode to about \(MarginMomentSequence.reviewLeadInMs / 1_000) seconds before \(name)'s Margin."
        case .playMarginNow:
            title = "Skip to \(name) now"
            hint = "Plays \(name)'s Margin now."
        case .skipVoice, .unavailable:
            title = "Next Margin"
            hint = nil
        }
    }
}
