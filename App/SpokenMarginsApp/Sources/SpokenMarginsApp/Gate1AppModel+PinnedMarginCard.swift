import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio

/// What the pinned Margin card on the Now screen shows and does (#3220). The words are `PinnedMarginCard` and the
/// two-press rule is `NextMarginPress`, both in SessionKit; this reads the model's state into them and carries out
/// the press. It sits in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// A friend's Margin after the playhead, in playing order, with its place in the episode (nil on a text item).
    /// Reads nothing unless the open item has a friend's Margin that can play.
    private var nextSharedMargin: (prompt: ImportedCommentaryPrompt, mediaTimeMs: Int?)? {
        guard hasEnabledImportedCommentary else { return nil }
        let prompts = importedCommentaryPrompts(includeAnnounced: true)
        if isMediaPlaybackSnapshot {
            // A Margin still waiting for its placement pass plays at the sender's time (#3059), so it counts too.
            func place(_ prompt: ImportedCommentaryPrompt) -> Int? {
                prompt.mediaTimeMs
            }
            guard let ms = NextMarginPress.nextMarginMs(after: snapshot.currentMediaTimeMs, among: prompts.compactMap(place)),
                  let prompt = prompts.first(where: { place($0) == ms }) else { return nil }
            return (prompt, ms)
        }
        // Text read aloud has no lead-in to seek to: Next Margin goes straight to the Margin.
        let from = snapshot.currentTextStart ?? -1
        let ahead = prompts.filter { ($0.interjection.resolution.localStartChar ?? -1) > from }
        guard let prompt = ahead.min(by: { ($0.interjection.resolution.localStartChar ?? .max) < ($1.interjection.resolution.localStartChar ?? .max) })
        else { return nil }
        return (prompt, nil)
    }

    /// The card, or nil when the slot is free. The slot is held for the whole of a friend's listen: a review or moment
    /// keeps its card between Margins, and with auto-play on the card shows the Margin still ahead, so the title below
    /// never moves when a Margin starts or ends.
    var pinnedMarginCard: PinnedMarginCard? {
        if let playing = playingImportedCommentary {
            let stage: PinnedMarginCard.Stage
            switch importedCommentaryPhase {
            case .loading: stage = .loading
            case .playing: stage = playing.interjection.isWritten ? .reading : .speaking // a synthetic voice is never "speaking" (#3365)
            case .paused: stage = .voicePaused
            case .failed: stage = .failed
            }
            return PinnedMarginCard(
                subject: .friend(SharedPacketArrival.senderName(playing.senderLabel)), stage: stage,
                position: PinnedMarginCard.position(playing.index, of: playing.count), voiceTime: playingVoiceTime,
                noun: sourceNoun, nextPress: nextMarginPress, canStartEarlier: stage == .speaking && startEarlierPlanForPlayingSharedMargin != nil)
        }
        if let pending = pendingImportedCommentary {
            return PinnedMarginCard(
                subject: .friend(SharedPacketArrival.senderName(pending.senderLabel)), stage: .waitingForTap,
                position: PinnedMarginCard.position(pending.index, of: pending.count), noun: sourceNoun)
        }
        if let moment = marginMoment {
            let current = moment.playing ?? moment.target
            let run: PinnedMarginCard.Run = moment.isReview ? .review : .moment
            let subject: PinnedMarginCard.Subject = current.isYours || !moment.isReview && current.label == nil
                ? .yours : .friend(current.label) // `Subject` drops every stand-in, "a friend" included
            let position = CantPlayListening.cardPosition(in: moment) // a review counts its Margins; one Margin is never "1 of 1"
            if moment.isPlayingMargin {
                // The episode's words before a Margin (#3392) are not the friend's: the card never says they wrote or spoke them.
                let sounding: PinnedMarginCard.Stage = CantPlayListening.isWordsStep(moment) ? .loading : (current.isReadAloud ? .reading : .speaking)
                return PinnedMarginCard(
                    subject: subject, stage: marginMomentVoiceIsPaused ? .voicePaused : sounding, position: position,
                    voiceTime: playingVoiceTime, noun: sourceNoun, nextPress: nextMarginPress, run: run,
                    chainsWithoutLeadIn: CantPlayListening.isCantPlayListening(moment), canStartEarlier: marginMomentStartEarlierPlan != nil)
            }
            // A plain moment that has played its Margin keeps listening for the others: the slot stays, saying so.
            if !moment.isReview, moment.phase == .listening {
                return PinnedMarginCard(subject: .yours, stage: .upNext(msRemaining: nil, arrival: .playsByItself), position: nil, noun: sourceNoun, run: run)
            }
            let remaining = moment.msUntilTarget(currentMediaTimeMs: moment.review == nil ? (marginMomentPositionMs ?? moment.startMediaTimeMs) : snapshot.currentMediaTimeMs)
            return PinnedMarginCard(subject: subject, stage: .comingUp(msRemaining: remaining), position: position, noun: sourceNoun,
                nextPress: nextMarginPress, run: run, targetLeadInMs: moment.target.leadInMs,
                canStartEarlier: marginMomentStartEarlierPlan != nil)
        }
        // A friend's Margin the listener went to that is never read aloud: its words, while the source is still near it (#4934).
        if let landing = shownSilentMarginLanding { return landing.card(noun: sourceNoun) }
        if let saved = friendAnswerSavedCard { return saved }
        // After a catch-up run, the card that says no answer is owed, ahead of any heard Margin still ahead (#4785).
        if let caughtUp = caughtUpCard { return caughtUp }
        // Auto-play off still holds the slot: Next Margin is reachable between Margins and the title never moves.
        guard let next = nextSharedMargin else { return friendLastMarginCard }
        let remaining = next.mediaTimeMs.flatMap { ms in snapshot.currentMediaTimeMs.map { max(0, ms - $0) } }
        let arrival = sharedMarginArrival(next.prompt)
        return PinnedMarginCard(
            subject: .friend(SharedPacketArrival.senderName(next.prompt.senderLabel)), stage: .upNext(msRemaining: remaining, arrival: arrival),
            position: PinnedMarginCard.position(next.prompt.index, of: next.prompt.count), noun: sourceNoun, nextPress: nextMarginPress,
            targetLeadInMs: next.prompt.interjection.senderLeadInMs)
    }

    /// The friend's Margin an ordinary countdown card is about (no Margin moment), so the card's line can say how its
    /// place may be off (#4175). Nil while a moment holds the card.
    var pinnedCardUpNextPrompt: ImportedCommentaryPrompt? {
        marginMoment == nil ? nextSharedMargin?.prompt : nil
    }

    /// What the open source is called on the card: from the open item's own stored facts (the Library row's), else from
    /// whether it plays as media. Never hard-coded to "episode" (#3597).
    var sourceNoun: SourceNoun {
        if let row = libraryItems.first(where: { $0.id == snapshot.itemId }) {
            return SourceNoun(mediaType: row.mediaType, sourceReference: row.sourceReference, sourceReferenceType: row.sourceReferenceType)
        }
        return isMediaPlaybackSnapshot ? .episode : .text
    }

    /// What the card's Next Margin would do now: from the press rule, or straight to the Margin on text read aloud,
    /// which has no lead-in (`goToNextMargin`). `.unavailable` when there is no later Margin to go to.
    var nextMarginPress: NextMarginPress {
        if marginMoment == nil, !isMediaPlaybackSnapshot { return nextSharedMargin != nil ? .playMarginNow : .unavailable }
        guard let context = nextMarginContext else { return .unavailable }
        return NextMarginPress.press(context)
    }

    /// How far through the sounding Margin voice is, from whichever player has it: a moment's (the conductor) or a
    /// friend's that plays by itself.
    private var playingVoiceTime: String? {
        if let reading = marginMomentConductor?.voiceReading {
            return PinnedMarginCard.voiceTime(current: reading.current, duration: reading.duration)
        }
        if playingImportedCommentary != nil, let item = marginVoicePlayer.currentPlayer?.currentItem {
            return PinnedMarginCard.voiceTime(current: item.currentTime().seconds, duration: item.duration.seconds)
        }
        return nil
    }

    /// What happens when the episode reaches `prompt`, from the same facts the offer uses, so the card and Next Margin
    /// never promise what the offer will not do.
    private func sharedMarginArrival(_ prompt: ImportedCommentaryPrompt) -> PinnedMarginCard.Arrival {
        .forMargin(prompt, offers: sharedMarginOffers)
    }

    private var nextMarginContext: NextMarginPress.Context? {
        if let moment = marginMoment {
            return moment.isPlayingMargin
                ? .momentVoice(isReview: moment.isReview, isLastMargin: moment.unplayed.isEmpty)
                : .momentLeadIn(
                    isReview: moment.isReview, positionMs: snapshot.currentMediaTimeMs, targetMs: moment.target.mediaTimeMs,
                    targetLeadInMs: moment.target.leadInMs, runUpStartMs: moment.targetRunUpStartMediaTimeMs)
        }
        guard let next = nextSharedMargin else { return nil }
        guard let ms = next.mediaTimeMs else { return nil }
        return .sharedPlayback(
            positionMs: snapshot.currentMediaTimeMs, nextMarginMs: ms, arrival: sharedMarginArrival(next.prompt),
            nextLeadInMs: next.prompt.interjection.senderLeadInMs)
    }

    /// The card's Next Margin: the first press goes to the next Margin's lead-in, the second goes straight to the
    /// Margin (#460).
    func goToNextMargin() {
        guard !recordingNavigationIsLocked else { return }
        if marginMoment == nil, !isMediaPlaybackSnapshot {
            guard let next = nextSharedMargin else { return }
            playSharedMarginNow(next.prompt)
            return
        }
        guard let context = nextMarginContext else { return }
        switch NextMarginPress.press(context) {
        case .unavailable: return
        case .playMarginNow:
            if marginMoment != nil { playMarginMomentNow() } else if let next = nextSharedMargin { playSharedMarginNow(next.prompt) }
        case .skipVoice:
            skipMarginMomentVoice()
        case .seekToLeadIn(let ms) where marginMoment != nil:
            // A review's episode plays on between Margins and nothing hops ahead by itself: this tap is the hop. The
            // review's own Margin plays when the episode reaches it, so nothing is marked or dismissed here.
            marginMomentConductor?.sourceMoved()
            seekMedia(toMediaTimeMs: ms)
        case .seekToLeadIn(let ms):
            // An announced Margin is not offered when the episode crosses it again, so give it back first: the lead-in
            // the press goes to must end with the Margin playing (#460).
            if let next = nextSharedMargin { sharedMarginOffers.markUnannounced([next.prompt.id]) }
            if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: true) }
            dismissPendingImportedCommentary()
            seekMedia(toMediaTimeMs: ms)
        }
    }

    // MARK: Start a minute earlier (#4171)

    /// The plan for "Start a minute earlier" in a running moment or review: the Margin playing, or the target while the
    /// playhead is inside its run-up (`MarginMomentSequence.startEarlierPlan`). Media only: an article read aloud counts its
    /// moment in characters, where "a minute" means nothing.
    private var marginMomentStartEarlierPlan: StartEarlier.Plan? {
        guard let moment = marginMoment, !marginMomentClock.isNarratedText, isMediaPlaybackSnapshot else { return nil }
        return moment.startEarlierPlan(currentMediaTimeMs: snapshot.currentMediaTimeMs)
    }

    /// A friend's Margin playing by itself as the episode reached it, as a review entry: where it plays, and whether that
    /// place is a best guess. Nil on a text item or for a Margin with no place in the episode.
    private var playingSharedMarginEntry: SharedMarginReview.Entry? {
        guard marginMoment == nil, isMediaPlaybackSnapshot, let playing = playingImportedCommentary else { return nil }
        return StartEarlier.entries(playing: playing, waiting: [], among: []).first
    }

    /// Ordinary playback had no run-up before that Margin, so the press gives it one minute (`StartEarlier.plan`, `R = 0`).
    private var startEarlierPlanForPlayingSharedMargin: StartEarlier.Plan? {
        playingSharedMarginEntry.flatMap { StartEarlier.plan(for: $0.anchor, runUpMs: 0) }
    }

    /// The card's "Start a minute earlier": in a running moment or review, the conductor plays the Margin again after a
    /// run-up one minute longer, keeping the review's count and its return place. For a friend's Margin playing by itself,
    /// a review of that one Margin starts with a one-minute run-up, and the episode plays on after it. The rule is
    /// `StartEarlier` in SessionKit; this only routes the press.
    func startMarginEarlier() {
        guard !recordingNavigationIsLocked else { return }
        if let conductor = marginMomentConductor {
            guard let plan = marginMomentStartEarlierPlan else { return }
            conductor.restartLonger(plan)
            diagnostics["marginMoment.startEarlier"] = "lead_in_ms=\(plan.leadInMs)"
            return
        }
        guard let playing = playingImportedCommentary, let entry = playingSharedMarginEntry, let itemId = snapshot.itemId,
              let plan = StartEarlier.plan(for: entry.anchor, runUpMs: 0) else { return }
        // The friend's Margins crossed with this one and still waiting their turn play after it (audit on #5093).
        let entries = StartEarlier.entries(
            playing: playing, waiting: sharedMarginOffers.waitingIDs, among: importedCommentaryPrompts(includeAnnounced: true))
        reviewNewMargins(itemId: itemId, thenContinue: true, entries: entries, startingEarlier: plan)
        diagnostics["marginMoment.startEarlier"] = "lead_in_ms=\(plan.leadInMs);from=auto_play"
    }

    /// Goes to a friend's Margin and plays it, whether the listener asked from the card or the episode got there.
    /// False when the jump failed; it has told the listener why.
    @discardableResult
    func playSharedMarginNow(_ prompt: ImportedCommentaryPrompt) -> Bool {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: true) } // the episode comes back, so the jump reads it as playing
        dismissPendingImportedCommentary()
        guard jumpToImportedCommentary(interjectionID: prompt.interjection.id) else { return false }
        listenToPendingImportedCommentary()
        return true
    }
}
