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
                SharedMarginPrompts.mediaTimeMs(prompt.interjection, in: prompt.layer)
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
            case .failed: stage = .failed(canMoveOn: canGoToNextMargin)
            }
            return PinnedMarginCard(
                subject: .friend(SharedPacketArrival.senderName(playing.senderLabel)), stage: stage,
                position: PinnedMarginCard.position(playing.index, of: playing.count), voiceTime: playingVoiceTime)
        }
        if let pending = pendingImportedCommentary {
            return PinnedMarginCard(
                subject: .friend(SharedPacketArrival.senderName(pending.senderLabel)), stage: .waitingForTap,
                position: PinnedMarginCard.position(pending.index, of: pending.count))
        }
        if let moment = marginMoment {
            let current = moment.playing ?? moment.target
            let subject: PinnedMarginCard.Subject = current.isYours || !moment.isReview && current.label == nil
                ? .yours : .friend(SharedPacketArrival.senderName(current.label))
            let position = moment.review.map { CantPlayListening.position(in: moment) ?? "\(moment.reviewNumber ?? 1) of \($0.count)" } // a review always counts, even one Margin
            if moment.isPlayingMargin {
                // The episode's words before a Margin (#3392) are not the friend's: the card never says they wrote or spoke them.
                let sounding: PinnedMarginCard.Stage = CantPlayListening.isWordsStep(moment) ? .loading : (current.isReadAloud ? .reading : .speaking)
                return PinnedMarginCard(
                    subject: subject, stage: marginMomentVoiceIsPaused ? .voicePaused : sounding, position: position,
                    voiceTime: playingVoiceTime)
            }
            // A plain moment that has played its Margin keeps listening for the others: the slot stays, saying so.
            if !moment.isReview, moment.phase == .listening {
                return PinnedMarginCard(subject: .yours, stage: .upNext(msRemaining: nil, arrival: .playsByItself), position: nil)
            }
            let remaining = moment.msUntilTarget(currentMediaTimeMs: moment.review == nil ? (marginMomentPositionMs ?? moment.startMediaTimeMs) : snapshot.currentMediaTimeMs)
            return PinnedMarginCard(subject: subject, stage: .comingUp(msRemaining: remaining), position: position)
        }
        if let saved = friendAnswerSavedCard { return saved }
        // Auto-play off still holds the slot: Next Margin is reachable between Margins and the title never moves.
        guard let next = nextSharedMargin else { return friendLastMarginCard }
        let remaining = next.mediaTimeMs.flatMap { ms in snapshot.currentMediaTimeMs.map { max(0, ms - $0) } }
        let arrival = sharedMarginArrival(next.prompt)
        return PinnedMarginCard(
            subject: .friend(SharedPacketArrival.senderName(next.prompt.senderLabel)), stage: .upNext(msRemaining: remaining, arrival: arrival),
            position: PinnedMarginCard.position(next.prompt.index, of: next.prompt.count), isFirstFromSender: next.prompt.index == 1)
    }

    /// The words on the skip button between a friend's Margins: from the press it will make and the sender of the
    /// Margin it goes to, so the label always describes the tap (#3247). Nil whenever the card is not that card.
    var nextMarginWords: NextMarginWords? {
        guard marginMoment == nil, playingImportedCommentary == nil, pendingImportedCommentary == nil,
              let next = nextSharedMargin else { return nil }
        // Text read aloud has no lead-in: the button goes straight to the Margin (`goToNextMargin`).
        let press: NextMarginPress = isMediaPlaybackSnapshot
            ? (nextMarginContext.map(NextMarginPress.press) ?? .unavailable) : .playMarginNow
        return NextMarginWords(press: press, subject: .friend(SharedPacketArrival.senderName(next.prompt.senderLabel)))
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

    /// What happens when the episode reaches `prompt`, from that Margin's own layer and the offer queue's memory, the
    /// same facts the offer uses, so the card and Next Margin never promise what the offer will not do.
    private func sharedMarginArrival(_ prompt: ImportedCommentaryPrompt) -> PinnedMarginCard.Arrival {
        .forMargin(announced: sharedMarginOffers.announcedIDs.contains(prompt.id), revealMode: prompt.layer.revealMode)
    }

    private var nextMarginContext: NextMarginPress.Context? {
        if let moment = marginMoment {
            return moment.isPlayingMargin
                ? .momentVoice(isReview: moment.isReview, isLastMargin: moment.unplayed.isEmpty)
                : .momentLeadIn(isReview: moment.isReview, positionMs: snapshot.currentMediaTimeMs, targetMs: moment.target.mediaTimeMs)
        }
        guard let next = nextSharedMargin else { return nil }
        guard let ms = next.mediaTimeMs else { return nil }
        return .sharedPlayback(positionMs: snapshot.currentMediaTimeMs, nextMarginMs: ms, arrival: sharedMarginArrival(next.prompt))
    }

    /// Whether the card's Next Margin button is enabled.
    var canGoToNextMargin: Bool {
        if marginMoment == nil, !isMediaPlaybackSnapshot { return nextSharedMargin != nil && !recordingNavigationIsLocked }
        guard !recordingNavigationIsLocked, let context = nextMarginContext else { return false }
        return NextMarginPress.press(context) != .unavailable
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

    /// Goes to a friend's Margin and plays it, whether the listener asked from the card or the episode got there.
    func playSharedMarginNow(_ prompt: ImportedCommentaryPrompt) {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: true) } // the episode comes back, so the jump reads it as playing
        dismissPendingImportedCommentary()
        guard jumpToImportedCommentary(interjectionID: prompt.interjection.id) else { return }
        listenToPendingImportedCommentary()
    }
}
