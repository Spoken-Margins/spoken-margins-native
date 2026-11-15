import Foundation

/// What the item screen offers for starting to listen, and what each control is called (#3219).
///
/// An item with Margins a friend sent that the listener hasn't heard used to offer four ways in: a button reading
/// "Continue" (or "Start listening", "Replay", "Listen now"), a "New Margins to hear" dialog behind it, and
/// "Review new Margins" and "Review Margins" side by side. A friend who had just imported a packet could not tell
/// which to tap (owner, 2026-11-02). With unheard friend Margins the screen now offers two choices whose words never
/// change: "Play", the episode with the Margins playing in place (the 2026-10-31 call, #3059), or
/// "Skip to Cole's Margins · 3 min", each Margin with its lead-in. The words are the ones the owner reviewed on the
/// #3247 screens; the length came from the blind test there, where newcomers asked how long the Margins take.
/// Everything else keeps today's single button and words.
///
/// #4125 adds two states for a friend's Margins that sit behind the listener's saved place, where "Play" would
/// resume past them and they would never be heard. There the words follow the place, on purpose (the owner,
/// 2026-11-12: "play should do that"): "Hear Sam's Margins first · 1 min" plays them and carries on, and the second
/// choice is "Listen without them", or "Play from the start" when the place is the very end of the episode.
public struct ItemListeningChoices: Equatable, Sendable {
    public static let playTitle = "Play"

    /// One unheard friend Margin, as much of it as the choices need.
    public struct WaitingMargin: Equatable, Sendable {
        /// The name the sender's packet carries; empty when it carries none.
        public let senderName: String
        /// The recording's length, or nil for a written Margin, which the on-device voice reads aloud.
        public let audioDurationMs: Int?
        /// The words a written Margin is read from.
        public let transcript: String
        /// The id of the listener's own Margin this one answers, nil unless it is a reply to them (#3889).
        public let replyToYouParentId: String?
        /// A reply to one of the listener's own Margins, as opposed to a new Margin from the friend.
        public var isReplyToYou: Bool { replyToYouParentId != nil }

        /// A reply whose parent Margin is not in this Library (#4174): replies never carry the Margin they answer.
        public let parentMissing: Bool

        public init(senderName: String, audioDurationMs: Int?, transcript: String, replyToYouParentId: String? = nil, parentMissing: Bool = false) {
            self.senderName = senderName
            self.audioDurationMs = audioDurationMs
            self.transcript = transcript
            self.replyToYouParentId = replyToYouParentId
            self.parentMissing = parentMissing
        }
    }

    /// What a button does. The screen switches on this and decides nothing itself.
    public enum Action: Equatable, Sendable {
        /// Start the item: carry on its saved session, or begin one. Margins ahead of the place play in place.
        case play
        /// Review the waiting Margins, each with its lead-in. With `thenContinue`, carry on from the saved place
        /// when the last one has played; without it the review is all the listener asked for.
        case reviewNewMargins(thenContinue: Bool)
        /// Carry on from the saved place, leaving the waiting Margins new (the offer's "Listen without them").
        case continueWithout
        /// A new session at 0, leaving the waiting Margins new. They are then ahead and play in place.
        case startFromBeginning
    }

    /// The big button's words.
    public let primaryTitle: String
    /// What VoiceOver reads for the big button when it isn't just its title; nil to read the title.
    public let primaryAccessibilityLabel: String?
    /// What the big button does.
    public let primaryAction: Action
    /// The second choice's words. Nil when the item has no unheard friend Margins, so there is nothing to choose.
    public let secondaryTitle: String?
    /// What VoiceOver reads for the second choice.
    public let secondaryAccessibilityLabel: String?
    /// What the second choice does; nil exactly when `secondaryTitle` is.
    public let secondaryAction: Action?

    /// The second choice's words when it is "Skip to <friend>'s Margins" (the state with nothing behind the place).
    public var marginsOnlyTitle: String? { secondaryAction == .reviewNewMargins(thenContinue: false) ? secondaryTitle : nil }
    /// What VoiceOver reads for that "Skip to …" choice: whose Margins, how many, and about how long.
    public var marginsOnlyAccessibilityLabel: String? {
        secondaryAction == .reviewNewMargins(thenContinue: false) ? secondaryAccessibilityLabel : nil
    }

    /// - Parameters:
    ///   - unheardFriendMargins: the friend Margins on this item that the listener can hear and hasn't.
    ///   - marginsBehindPlace: those of them that sit behind the place Play would resume (`PlayRule
    ///     .marginsBehindSavedPlace`), empty when none does or the place isn't known. The screen leaves it empty
    ///     for a listener who already turned the offer down in this run.
    ///   - placeIsAtEnd: that place is the end of the episode (`PlayRule.savedPlaceIsAtEnd`).
    ///   - hasFinishedSession: the item's session reached its end, so the plain button says "Replay".
    ///   - hasContinuationSession: the item has a session to carry on, so the plain button says "Continue".
    ///   - isPreparingAudio: the item's audio is still being made or fetched, so the plain button says "Listen now".
    public init(
        unheardFriendMargins: [WaitingMargin],
        marginsBehindPlace: [WaitingMargin] = [],
        placeIsAtEnd: Bool = false,
        hasFinishedSession: Bool,
        hasContinuationSession: Bool,
        isPreparingAudio: Bool
    ) {
        if !marginsBehindPlace.isEmpty {
            // Margins the episode would skip. The first button plays exactly these, then carries on, so the words
            // and the minutes are counted over them.
            let (whose, counted) = Self.describe(marginsBehindPlace)
            let minutes = Self.marginsOnlyMinutes(marginsBehindPlace)
            primaryTitle = "Hear \(whose) first · \(minutes) min"
            primaryAction = .reviewNewMargins(thenContinue: true)
            primaryAccessibilityLabel = "Hear \(whose) first, \(counted), about \(minutes) minute\(minutes == 1 ? "" : "s"), "
                + "then carry on from where you were."
            if placeIsAtEnd {
                secondaryTitle = "Play from the start"
                secondaryAccessibilityLabel = "Play from the start"
                secondaryAction = .startFromBeginning
            } else {
                secondaryTitle = "Listen without them"
                secondaryAccessibilityLabel = "Listen without them. \(Self.capitalizingFirst(whose)) stay new."
                secondaryAction = .continueWithout
            }
        } else if !unheardFriendMargins.isEmpty {
            // The same words whether or not the episode was heard, started or is still being prepared: the two
            // choices describe what will play, not where the listener is in the item.
            let (whose, counted) = Self.describe(unheardFriendMargins)
            let minutes = Self.marginsOnlyMinutes(unheardFriendMargins)
            primaryTitle = Self.playTitle
            primaryAccessibilityLabel = nil
            primaryAction = .play
            secondaryTitle = "Skip to \(whose) · \(minutes) min"
            secondaryAccessibilityLabel = "Skip to \(whose), \(counted), "
                + "about \(minutes) minute\(minutes == 1 ? "" : "s")"
            secondaryAction = .reviewNewMargins(thenContinue: false)
        } else {
            if isPreparingAudio {
                primaryTitle = "Listen now"
            } else if hasFinishedSession {
                primaryTitle = "Replay"
            } else {
                primaryTitle = hasContinuationSession ? "Continue" : "Start listening"
            }
            primaryAccessibilityLabel = nil
            primaryAction = .play
            secondaryTitle = nil
            secondaryAccessibilityLabel = nil
            secondaryAction = nil
        }
    }

    /// Whose they are and how many, for the words around `margins`. Replies only: "Sam's replies" (the reply, when
    /// there is one), counted as replies to the listener's Margins (#3889). Anything else keeps "Sam's Margins" and
    /// counts new Margins.
    private static func describe(_ margins: [WaitingMargin]) -> (whose: String, counted: String) {
        let mix = FriendReplyMix(margins)
        let whose = mix.isAllReplies
            ? Self.whose(margins, noun: mix.replies == 1 ? "reply" : "replies")
            : Self.whoseMargins(margins)
        let counted = mix.hasReplies ? mix.spokenCount : "\(mix.total) new Margin\(mix.total == 1 ? "" : "s")"
        return (whose, counted)
    }

    private static func capitalizingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Cole's Margins" when one named friend sent them all; "the Margins" for several friends or none named.
    static func whoseMargins(_ margins: [WaitingMargin]) -> String {
        whose(margins, noun: "Margins")
    }

    /// "Cole's replies" when one named friend sent them all; "the replies" for several friends or none named.
    static func whose(_ margins: [WaitingMargin], noun: String) -> String {
        guard let name = FriendMarginsIntro.singleName(margins) else { return "the \(noun)" }
        return "\(name)'s \(noun)"
    }

    /// How long "Skip to …" takes, in whole minutes and never under one: each Margin, written ones at the on-device
    /// voice's pace, plus the review's lead-in before each.
    static func marginsOnlyMinutes(_ margins: [WaitingMargin]) -> Int {
        let leadInMs = ListeningMoment.rule(for: .reviewNewMargins).leadInMs
        let totalMs = margins.reduce(0) { sum, margin in
            sum + leadInMs + max(0, margin.audioDurationMs ?? spokenLengthMs(of: margin.transcript))
        }
        return max(1, Int((Double(totalMs) / 60_000).rounded()))
    }

    /// About 2.5 words a second, the on-device voice's ordinary pace.
    static func spokenLengthMs(of text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return words * 400
    }
}

extension SharedMarginReview.Entry {
    /// This Margin as the item screen's choices see it (#3219).
    public var waitingMargin: ItemListeningChoices.WaitingMargin {
        ItemListeningChoices.WaitingMargin(
            senderName: layer.displayLabel ?? "",
            audioDurationMs: interjection.audioDurationMs,
            transcript: interjection.approvedTranscript,
            replyToYouParentId: replyContext?.yoursParentId,
            parentMissing: replyContext?.parent == .missing
        )
    }
}
