import Foundation

/// What the pinned Margin card on the Now screen says and offers (#3220, #3597). One card serves a review of new
/// Margins, "Play this moment" and a friend's Margin that plays by itself as the source reaches it, so the listener sees
/// one playback experience. Every stage has the same three parts: a headline, one line of detail and one row of
/// buttons. The headline, the detail and the button titles all come from this one value, built from the stage and the
/// press the Next Margin button would make, so the words and the buttons cannot disagree. The view only draws them.
public struct PinnedMarginCard: Equatable, Sendable {
    /// Whose Margin the card is about.
    public enum Subject: Equatable, Sendable {
        case yours
        /// A friend's Margin, with the name on their layer when it has one.
        case friend(String?)

        /// The sender's cleaned name, nil for your own Margin and for a sender with no name.
        public var name: String? {
            switch self {
            case .yours: nil
            case .friend(let name): Self.cleaned(name)
            }
        }

        /// The sender's name with every stand-in dropped, so a stand-in is never a name on the card. Besides the labels
        /// `SharedPacketArrival.senderName` knows, this drops "a friend" and "your friend", which the Timeline's
        /// `collectionLabel` puts on a Margin with no sender (#3597).
        public static func cleaned(_ label: String?) -> String? {
            guard let name = SharedPacketArrival.senderName(label) else { return nil }
            let folded = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return ["a friend", "your friend", "friend"].contains(folded) ? nil : name
        }

        /// "Margin from Cole". With no name, "Shared Margin": never "A friend" unless a friend is named.
        public var title: String {
            switch self {
            case .yours: "Your Margin"
            case .friend: name.map { "Margin from \($0)" } ?? "Shared Margin"
            }
        }

        /// "Loading Cole's Margin" (#3392's words), "Loading this Margin" with no name.
        public var loadingTitle: String {
            switch self {
            case .yours: "Loading your Margin"
            case .friend: name.map { "Loading \($0)'s Margin" } ?? "Loading this Margin"
            }
        }

        /// Whose words the iPhone's voice is reading: "Cole's words", or "this Margin" with no name.
        public var wordsOwner: String {
            switch self {
            case .yours: "your words"
            case .friend: name.map { "\($0)'s words" } ?? "this Margin"
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
        /// The voice could not play. Whether Next Margin has somewhere to go is `hasNextMargin`.
        case failed
        /// A lead-in is under way: the Margin plays when the source reaches it (or when the listener says so).
        case comingUp(msRemaining: Int?)
        /// A Margin is here and waits for the listener's tap (tone-only or jumped to).
        case waitingForTap
        /// Between Margins of a friend's listen: the next one is `msRemaining` ahead, nil when that is not known.
        case upNext(msRemaining: Int?, arrival: Arrival)
        /// A friend just saved a Margin of their own: it can be sent with Share (`answerSaved`). `atMs` is its place in the
        /// source, nil on text; `sentTo` is who it would go to.
        case answerSaved(atMs: Int?, sentTo: String)
        /// The last of a friend's Margins has played and none is ahead (`friendsLast`). `senders` is how many people's
        /// Margins the item holds; the subject names the one when there is one.
        case lastMargin(senders: Int)
    }

    /// What happens when the source gets to the next Margin.
    public enum Arrival: Equatable, Sendable {
        /// Auto-play is on and the Margin is new to this run of the source: it plays by itself.
        case playsByItself
        /// Auto-play is off: a tone sounds and the listener taps Listen.
        case toneThenTap
        /// The Margin was announced already (a finished review, or heard before the listener scrubbed back), so
        /// reaching it plays nothing. Next Margin plays it.
        case onRequest
        /// The Margin was announced (the tone sounded, or it was dismissed) but its voice never played for this listener.
        /// Reaching it plays nothing, and the card never says they heard it.
        case announcedUnheard
        /// The Margin's layer is Fresh: the source never offers it. Next Margin plays it, with no lead-in to wait through.
        case waitsForYou

        /// What happens when the source reaches a Margin, from the same rules the offer uses: a Fresh layer is never
        /// offered, an announced Margin is not offered again, and otherwise the layer's own reveal mode decides
        /// (`SharedMarginPromptStyle`). Per Margin, never per item: layers on one source can differ.
        public static func forMargin(announced: Bool, heard: Bool = true, revealMode: ImportedCommentaryRevealMode?) -> Arrival {
            if revealMode == .fresh { return .waitsForYou }
            if announced { return heard ? .onRequest : .announcedUnheard }
            let style = SharedMarginPromptStyle.style(revealMode: revealMode, arrival: .crossed)
            return style.autoPlayAfterMs != nil ? .playsByItself : .toneThenTap
        }
    }

    public let subject: Subject
    public let stage: Stage
    /// Which Margin of how many, "1 of 3". Nil when the card is not counting: one Margin is never "1 of 1".
    public let position: String?
    /// How far through the voice, "0:14 of 0:41", while it plays. Nil when the voice has no readable clock yet.
    public let voiceTime: String?
    /// What the open source is called: "Episode", "Article" or "PDF".
    public let noun: SourceNoun
    /// What the Next Margin button would do right now; `.unavailable` when there is no later Margin to go to.
    public let nextPress: NextMarginPress
    /// What kind of run the card sits in. A friend's Margin that plays by itself is `.none`.
    public let run: Run

    /// "Hear only Margins" and a can't-play listening are a review: the Margins follow one another and Next Margin moves
    /// between them. "Play this moment" is a moment. A Margin that plays when the episode reaches it is in no run.
    public enum Run: Equatable, Sendable { case none, moment, review }

    public init(
        subject: Subject, stage: Stage, position: String? = nil, voiceTime: String? = nil,
        noun: SourceNoun = .episode, nextPress: NextMarginPress = .unavailable, run: Run = .none
    ) {
        self.run = run
        self.subject = subject
        self.stage = stage
        self.position = position
        self.voiceTime = voiceTime
        self.noun = noun
        self.nextPress = nextPress
    }

    /// Next Margin is on the card while a Margin sounds or has failed: only inside a review with more to come. A Margin
    /// that plays by itself, or a moment's, is skipped instead and the episode carries on, so nobody is teleported
    /// (owner, 2026-11-06). One fact for the words ("Tap Retry, or Next Margin to move on") and the button.
    public var hasNextMargin: Bool { run == .review && nextPress != .unavailable }

    /// What a Margin waiting for a tap shows under its headline: what it says, so the listener can choose. Only when the
    /// listener chooses; a Margin that plays by itself after a beat keeps the card's own line, so the card does not
    /// change height when the voice starts. Capped so Listen and Dismiss stay on the screen.
    public static func waitingTranscript(_ transcript: String?, playsByItself: Bool) -> String? {
        guard !playsByItself, let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else { return nil }
        return said.count <= 240 ? said : String(said.prefix(240)).trimmingCharacters(in: .whitespaces) + "…"
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

    /// The card's one-line headline: "Margin from Cole", "Margin from Cole in 0:08".
    public var headline: String {
        let title = subject.title
        switch stage {
        case .speaking, .reading: return title
        case .voicePaused: return "\(title) is paused"
        case .loading: return subject.loadingTitle
        case .failed: return "\(title) could not play"
        case .comingUp(let ms): return ms.map { "\(title) in \(Self.countdown($0))" } ?? "\(title) is coming up"
        case .waitingForTap: return "\(title) is here"
        case .upNext(let ms, let arrival): return upNextHeadline(msRemaining: ms, arrival: arrival)
        case .answerSaved(let atMs, _):
            return "Your Margin is saved" + (atMs.map { " at \(SharedMarginReview.ReplyContext.clock($0))" } ?? "")
        case .lastMargin(let senders):
            if senders > 1 { return "That was the last of your friends' Margins" }
            return subject.name.map { "That was \($0)'s last Margin" } ?? "That was the last Margin"
        }
    }

    private func upNextHeadline(msRemaining ms: Int?, arrival: Arrival) -> String {
        // The listener's own Margins, waiting for the others to come round.
        if case .yours = subject { return ms.map { "Your next Margin \(Self.friendCountdown($0))" } ?? "Your next Margin is ahead" }
        if arrival == .onRequest { return "You've heard this one" }
        return ms.map { "Next Margin \(Self.friendCountdown($0))" } ?? "Next Margin is ahead"
    }

    /// The second line, which says what the source is doing, so the card keeps one shape in every stage.
    public var detail: String {
        let heading = self.noun.capitalized
        switch stage {
        case .speaking: return voiceTime.map { "\($0) · \(heading) paused while it plays." } ?? "\(heading) paused while it plays."
        case .reading: return "Your phone's voice is reading \(subject.wordsOwner)."
        case .voicePaused: return voiceTime.map { "\($0) · \(heading) stays paused." } ?? "\(heading) stays paused."
        case .loading: return "Hold on, this is getting ready."
        case .failed:
            return hasNextMargin ? "Tap Retry, or Next Margin to move on." : "Tap Retry, or skip this Margin."
        case .comingUp: return "It plays by itself when the \(self.noun.inSentence) gets there."
        case .waitingForTap: return "Tap Listen to hear it."
        case .answerSaved(_, let sentTo): return "To send it to \(sentTo), tap Share below. You pick which of your Margins go."
        case .lastMargin(let senders):
            return "To answer\(senders > 1 ? " your friends" : subject.name.map { " \($0)" } ?? ""), add a Margin of your own."
        case .upNext(let ms, let arrival):
            if case .yours = subject { return "Plays by itself when you get there." }
            switch arrival {
            case .playsByItself: return "Plays by itself when you get there."
            case .toneThenTap: return "You'll hear a tone. Tap Listen to hear it."
            case .announcedUnheard: return "It won't play by itself."
            case .onRequest: return ms.map { "It's \(Self.friendSpan($0)) ahead and won't play by itself." } ?? "It won't play by itself."
            case .waitsForYou: return "This one waits for you."
            }
        }
    }

    /// "11 min" for a friend's Margin ahead, in whole minutes rounded up so it never promises an early arrival;
    /// "under 1 min" below a minute, then "15 sec" from the lead-in on (the last `reviewLeadInMs`). It counts the
    /// source's own time, so it runs long at a speed above 1x. Never "0 min" (#3247).
    public static func friendSpan(_ ms: Int) -> String {
        let ms = max(0, ms)
        if ms <= MarginMomentSequence.reviewLeadInMs {
            return "\(max(1, (ms + 999) / 1_000)) sec"
        }
        if ms < 60_000 { return "under 1 min" }
        return "\((ms + 59_999) / 60_000) min"
    }

    /// "in 11 min": `friendSpan` for a headline.
    public static func friendCountdown(_ ms: Int) -> String { "in \(friendSpan(ms))" }

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
        /// A review or "Play this moment" is waiting at its lead-in. In a review the episode plays on between Margins,
        /// so `positionMs` and `targetMs` (the playhead and the Margin ahead, nil when not known) say how far off it is.
        case momentLeadIn(isReview: Bool, positionMs: Int? = nil, targetMs: Int? = nil)
        /// A review's or moment's voice is sounding.
        case momentVoice(isReview: Bool, isLastMargin: Bool)
        /// No moment is running: the episode plays and a friend's Margins come as it reaches them. `positionMs` is the
        /// playhead, `nextMarginMs` the next friend's Margin after it, either nil when not known.
        case sharedPlayback(positionMs: Int?, nextMarginMs: Int?, arrival: PinnedMarginCard.Arrival)
    }

    private static let leadInSlackMs = 1_000

    public static func press(_ context: Context) -> NextMarginPress {
        switch context {
        case .momentLeadIn(let isReview, let position, let target):
            guard isReview else { return .unavailable }
            // The episode plays on between a review's Margins and nothing hops ahead by itself: the first press goes to the
            // next Margin's lead-in, the second plays the Margin. A second of slack, so the lead-in's own seek (which can
            // land a millisecond short) is not offered as a hop of its own.
            if let position, let target {
                let leadIn = MarginMomentSequence.leadInStartMediaTimeMs(
                    forTarget: MarginMomentAnchor(marginId: "next", mediaTimeMs: target),
                    leadInMs: MarginMomentSequence.reviewLeadInMs
                )
                if position + leadInSlackMs < leadIn { return .seekToLeadIn(mediaTimeMs: max(0, leadIn)) }
            }
            return .playMarginNow
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
