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
            /// Stops a review: the voice stops and the source PAUSES. If no Margin of the review has played yet it goes back
            /// to where the listener was; after that it stays where it is, unless the listener's own place was ahead
            /// (`MarginMomentSequence.placeToReturnToWhenStopped`).
            case stopReview
            /// Stops a plain moment that is listening for the listener's other Margins.
            case stopPlayingMine
            case listen
            case dismiss

            /// Held while a Margin is being recorded (`recordingNavigationIsLocked`): drawn dimmed, not hidden.
            public var followsNavigationLock: Bool { self == .goToNextMargin }
        }

        public enum Prominence: Equatable, Sendable { case primary, secondary, quiet }

        public let job: Job
        public let title: String
        /// What the tap does, for VoiceOver.
        public let hint: String
        public let prominence: Prominence
    }

    /// The card's buttons, left to right. Empty when nothing on the card has anywhere to go.
    public var actions: [Action] {
        let ahead = noun.inSentence
        let skip = Action(job: .skipThisMargin, title: "Skip this Margin", hint: "Stops this Margin and carries on with the \(ahead).", prominence: .secondary)
        let stop = Action(
            job: .stopReview, title: "Stop",
            hint: "Stops these Margins and pauses the \(ahead). If none of them has played yet, it goes back to where you were.",
            prominence: .quiet)
        switch stage {
        case .speaking, .reading, .voicePaused, .loading:
            // The one button while a voice sounds skips it: the episode plays on from where the Margin ended. It never says
            // "Next Margin", because stopping a voice does not move the listener to the next one; the next Margin's own
            // lead-in button ("Jump to 20 sec before it") comes once the voice is over (audit on #3623).
            // A review has no lead-in to leave from while its Margins chain (a can't-play listening), so Stop is here too.
            return run == .review ? [skip, stop] : [skip]
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
        case .answerSaved, .lastMargin:
            return []
        }
    }

    /// The lead-in. A review's main button is the press, as between a friend's Margins: far off it hops to the lead-in, near it
    /// plays the Margin. Its quiet exit is Stop, which pauses (the episode plays on between a review's Margins, so
    /// "back to the episode" would be false). A plain moment plays on from the lead-in, so "Keep listening" is true.
    private func comingUpActions(ahead: String, stop: Action) -> [Action] {
        let playNow = Action(job: .playMomentNow, title: "Play it now", hint: "Plays the Margin now, without waiting for the \(ahead).", prominence: .primary)
        guard run == .review else {
            return [
                playNow,
                Action(job: .keepListening, title: "Keep listening", hint: "Stops the lead-in. The \(ahead) carries on from here, as it was.", prominence: .quiet),
            ]
        }
        if case .seekToLeadIn = nextPress {
            let seconds = MarginMomentSequence.reviewLeadInMs / 1_000
            let hop = Action(job: .goToNextMargin, title: "Jump to \(seconds) sec before it", hint: "Moves the \(ahead) to about \(seconds) seconds before this Margin.", prominence: .primary)
            return [hop, stop]
        }
        return [playNow, stop]
    }

    /// Between a friend's Margins the one button is the press the tap makes. No later Margin, no button.
    private func upNextAction(arrival: Arrival, ahead: String) -> Action? {
        let leadInSeconds = MarginMomentSequence.reviewLeadInMs / 1_000
        switch nextPress {
        case .unavailable:
            return nil
        case .seekToLeadIn:
            if arrival == .onRequest {
                return Action(job: .goToNextMargin, title: "Hear it again", hint: "Moves the \(ahead) to about \(leadInSeconds) seconds before this Margin, so you can hear it again.", prominence: .secondary)
            }
            return Action(job: .goToNextMargin, title: "Jump to \(leadInSeconds) sec before it", hint: "Moves the \(ahead) to about \(leadInSeconds) seconds before the next Margin.", prominence: .secondary)
        case .playMarginNow:
            // A Margin the card calls heard says "Hear it again", whichever press the tap makes; the words and the button agree.
            if arrival == .onRequest {
                return Action(job: .goToNextMargin, title: "Hear it again", hint: "Plays this Margin again.", prominence: .secondary)
            }
            return Action(job: .goToNextMargin, title: "Play it now", hint: "Plays the next Margin now.", prominence: .secondary)
        case .skipVoice:
            return Action(job: .goToNextMargin, title: "Next Margin", hint: "Goes on to the next Margin.", prominence: .secondary)
        }
    }
}
