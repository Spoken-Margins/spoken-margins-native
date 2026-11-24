import Foundation

/// The buttons on the pinned Margin card (#3597): one row, one button per job, and none that has nowhere to go. Titles
/// and VoiceOver hints come from the stage and the press the Next Margin button would make, so a button never says
/// something its tap does not do. The view maps each `Job` to the model call it already had.
extension PinnedMarginCard {
    public struct Action: Equatable, Sendable {
        /// What the tap does. The app carries it out.
        public enum Job: Hashable, Sendable {
            /// The Next Margin press (`NextMarginPress`): to the next Margin's lead-in, or straight to the Margin.
            case goToNextMargin
            /// Stops the Margin that is sounding or failed; the source carries on.
            case skipThisMargin
            case retry
            /// "Play this moment" or a review, at its lead-in: play the Margin now.
            case playMomentNow
            /// Ends a plain moment's lead-in; the source keeps its play state (`MarginMomentConductor.cancel`).
            case keepListening
            /// Stops a review (from its lead-in, or while a can't-play listening's voice plays): the source PAUSES. If no Margin of the review has played yet it goes back
            /// to where the listener was; after that it stays where it is, unless the listener's own place was ahead
            /// (`MarginMomentSequence.placeToReturnToWhenStopped`).
            case stopReview
            /// Stops a plain moment that is listening for the listener's other Margins.
            case stopPlayingMine
            case listen
            case dismiss
            /// Hides the card for a Margin the listener went to that is never spoken; the source keeps playing (#4934).
            case dismissSilentMargin
            /// "Start a minute earlier" (#4171): plays this Margin again after one more minute of the source
            /// (`StartEarlier`). Shown in a friend's run-up and while a friend's voice plays, never at AX3 and above.
            case startEarlier

            /// Held while a Margin is being recorded (`recordingNavigationIsLocked`): drawn dimmed, not hidden.
            public var followsNavigationLock: Bool { self == .goToNextMargin || self == .startEarlier }
        }

        public enum Prominence: Equatable, Sendable { case primary, secondary, quiet }

        public let job: Job
        public let title: String
        /// What the tap does, for VoiceOver.
        public let hint: String
        public let prominence: Prominence
    }

    /// The buttons the card draws at a text size: `actions`, without "Start a minute earlier" at accessibility3 and above,
    /// so the stacked card stays inside its height budget (#4171 Design; `PinnedMarginCardLayoutTests`). The view and its
    /// layout test both read this, so they can't disagree about which buttons are on the card.
    public func shownActions(atAccessibility3OrLarger large: Bool) -> [Action] {
        large ? actions.filter { $0.job != .startEarlier } : actions
    }

    /// "Start a minute earlier", where the card offers it: a friend's Margin (never the listener's own), a listening with a
    /// run-up to lengthen (never a can't-play one, which has none), and a plan the model found.
    private var startEarlier: Action? {
        guard canStartEarlier, case .friend = subject, !chainsWithoutLeadIn else { return nil }
        return Action(
            job: .startEarlier, title: "Start a minute earlier",
            hint: "Plays one more minute of the \(noun.inSentence) before this Margin.", prominence: .secondary)
    }

    /// The card's buttons, left to right. Empty when nothing on the card has anywhere to go.
    public var actions: [Action] {
        let ahead = noun.inSentence
        let skip = Action(job: .skipThisMargin, title: "Skip this Margin", hint: "Stops this Margin and carries on with the \(ahead).", prominence: .secondary)
        let stop = Action(
            job: .stopReview, title: "Stop Margins",
            hint: "Stops these Margins and pauses the \(ahead). If none of them has played yet, it goes back to where you were.",
            prominence: .quiet)
        switch stage {
        case .speaking, .reading, .voicePaused, .loading:
            // The one button while a voice sounds skips it: the episode plays on from where the Margin ended. It never says
            // "Next Margin", because stopping a voice does not move the listener to the next one; the next Margin's own
            // lead-in button ("Skip to just before Cole", for a friend's) comes once the voice is over (audit on #3623).
            // Never a Stop beside it: three exits for one short voice (#3597 proposal: "No Stop button; the pause control
            // already does that job"). The one exception is a can't-play listening: its Margins chain with no lead-in, so
            // the lead-in's Stop never comes and pause leaves the review armed. Stop stays there as the way out.
            if run == .review && chainsWithoutLeadIn { return [skip, stop] }
            // While a friend's voice plays, the listener may want more of the episode first (#4171): a second job, not a
            // second exit. Only while it speaks: a paused or loading voice keeps its one button.
            if stage == .speaking, let startEarlier { return [skip, startEarlier] }
            return [skip]
        case .failed:
            let retry = Action(job: .retry, title: "Retry", hint: "Tries to play this Margin again.", prominence: .secondary)
            return [retry, skip]
        case .comingUp:
            return comingUpActions(ahead: ahead, stop: stop)
        case .waitingForTap:
            return [
                Action(job: .listen, title: "Listen", hint: "Plays this Margin.", prominence: .primary),
                Action(job: .dismiss, title: "Dismiss", hint: "Leaves this Margin unplayed.", prominence: .quiet),
            ]
        case .upNext(_, let arrival):
            if case .yours = subject {
                return [Action(job: .stopPlayingMine, title: "Stop playing my Margins", hint: "Your other Margins stop playing by themselves.", prominence: .secondary)]
            }
            return upNextAction(arrival: arrival, ahead: ahead).map { [$0] } ?? []
        case .silentHere:
            // No Next Margin: the Skim arrows sit right under the card.
            return [Action(job: .dismissSilentMargin, title: "Dismiss", hint: "Hides this card. The \(ahead) keeps playing.", prominence: .quiet)]
        case .answerSaved, .savedHere, .lastMargin:
            return []
        }
    }

    /// The two presses between a friend's Margins read as one action, "Skip to …", the words the owner said yes to on
    /// 2026-11-05 (#3791): the first goes to just before the Margin, the second to the Margin. Your own Margins keep
    /// "Jump to 20 sec before it" and "Play it now"; his answer was for a friend's.
    ///
    /// The name in a button is its short form (`Subject.buttonName`): at the largest text size a button wraps and stacks
    /// under its words, and a full long name made the card taller than half the screen (#4001, the reason #3979 was
    /// reverted). The headline and the other lines keep the full name.
    private var playNowTitle: String {
        guard case .friend = subject else { return "Play it now" }
        return "Skip to \(subject.buttonName ?? "it") now"
    }

    /// How far before the Margin the hop goes: the sender's choice for this Margin (#4171), else the review's 20 sec.
    private var leadInSeconds: Int {
        (targetLeadInMs ?? MarginMomentSequence.reviewLeadInMs) / 1_000
    }

    /// "20 seconds", "1 minute", "90 seconds": a whole number of minutes reads as minutes.
    static func span(seconds: Int) -> String {
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private func hopTitle(seconds: Int) -> String {
        guard case .friend = subject else { return "Jump to \(seconds) sec before it" }
        return "Skip to just before \(subject.buttonName ?? "it")"
    }

    /// The lead-in. A review's main button is the press, as between a friend's Margins: far off it hops to the lead-in, near it
    /// plays the Margin. Its quiet exit is Stop, which pauses (the episode plays on between a review's Margins, so
    /// "back to the episode" would be false). A plain moment plays on from the lead-in, so "Keep listening" is true.
    private func comingUpActions(ahead: String, stop: Action) -> [Action] {
        let playNow = Action(job: .playMomentNow, title: playNowTitle, hint: "Plays the Margin now, without waiting for the \(ahead).", prominence: .primary)
        guard run == .review else {
            return [
                playNow,
                startEarlier,
                Action(job: .keepListening, title: "Keep listening", hint: "Stops the lead-in. The \(ahead) carries on from here, as it was.", prominence: .quiet),
            ].compactMap { $0 }
        }
        if case .seekToLeadIn = nextPress {
            let seconds = leadInSeconds
            let hop = Action(job: .goToNextMargin, title: hopTitle(seconds: seconds), hint: "Moves the \(ahead) to about \(Self.span(seconds: seconds)) before this Margin.", prominence: .primary)
            return [hop, stop] // far off, a longer run-up would move the listener forward: no "Start a minute earlier"
        }
        return [playNow, startEarlier, stop].compactMap { $0 }
    }

    /// Between a friend's Margins the one button is the press the tap makes. No later Margin, no button.
    private func upNextAction(arrival: Arrival, ahead: String) -> Action? {
        let leadInSeconds = self.leadInSeconds
        switch nextPress {
        case .unavailable:
            return nil
        case .seekToLeadIn:
            if arrival == .onRequest {
                return Action(job: .goToNextMargin, title: "Hear it again", hint: "Moves the \(ahead) to about \(Self.span(seconds: leadInSeconds)) before this Margin, so you can hear it again.", prominence: .secondary)
            }
            return Action(job: .goToNextMargin, title: hopTitle(seconds: leadInSeconds), hint: "Moves the \(ahead) to about \(Self.span(seconds: leadInSeconds)) before the next Margin.", prominence: .secondary)
        case .playMarginNow:
            // A Margin the card calls heard says "Hear it again", whichever press the tap makes; the words and the button agree.
            if arrival == .onRequest {
                return Action(job: .goToNextMargin, title: "Hear it again", hint: "Plays this Margin again.", prominence: .secondary)
            }
            return Action(job: .goToNextMargin, title: playNowTitle, hint: "Plays the next Margin now.", prominence: .secondary)
        case .skipVoice:
            return Action(job: .goToNextMargin, title: "Next Margin", hint: "Goes on to the next Margin.", prominence: .secondary)
        }
    }
}
