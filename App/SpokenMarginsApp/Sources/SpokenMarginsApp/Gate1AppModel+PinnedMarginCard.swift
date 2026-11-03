import Foundation
import SessionKit

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
            case .playing: stage = .speaking
            case .paused: stage = .voicePaused
            case .failed: stage = .failed
            }
            return PinnedMarginCard(
                subject: .friend(playing.senderLabel), stage: stage,
                position: PinnedMarginCard.position(playing.index, of: playing.count))
        }
        if let pending = pendingImportedCommentary {
            return PinnedMarginCard(
                subject: .friend(pending.senderLabel), stage: .waitingForTap,
                position: PinnedMarginCard.position(pending.index, of: pending.count))
        }
        if let moment = marginMoment {
            let current = moment.playing ?? moment.target
            let subject: PinnedMarginCard.Subject = current.isYours || !moment.isReview && current.label == nil
                ? .yours : .friend(current.label)
            let position = moment.review.map { "\(moment.reviewNumber ?? 1) of \($0.count)" } // a review always counts, even one Margin
            if moment.isPlayingMargin {
                return PinnedMarginCard(subject: subject, stage: marginMomentVoiceIsPaused ? .voicePaused : .speaking, position: position)
            }
            // A plain moment that has played its Margin keeps listening for the others: the slot stays, saying so.
            if !moment.isReview, moment.phase == .listening {
                return PinnedMarginCard(subject: .yours, stage: .upNext(msRemaining: nil), position: nil)
            }
            let remaining = moment.msUntilTarget(currentMediaTimeMs: moment.review == nil ? (marginMomentPositionMs ?? moment.startMediaTimeMs) : snapshot.currentMediaTimeMs)
            return PinnedMarginCard(subject: subject, stage: .comingUp(msRemaining: remaining), position: position)
        }
        guard importedCommentaryAutoPlayEnabled, let next = nextSharedMargin else { return nil }
        let remaining = next.mediaTimeMs.flatMap { ms in snapshot.currentMediaTimeMs.map { max(0, ms - $0) } }
        return PinnedMarginCard(
            subject: .friend(next.prompt.senderLabel), stage: .upNext(msRemaining: remaining),
            position: PinnedMarginCard.position(next.prompt.index, of: next.prompt.count))
    }

    private var nextMarginContext: NextMarginPress.Context? {
        if let moment = marginMoment {
            return moment.isPlayingMargin
                ? .momentVoice(isReview: moment.isReview, isLastMargin: moment.unplayed.isEmpty)
                : .momentLeadIn(isReview: moment.isReview)
        }
        guard let next = nextSharedMargin else { return nil }
        guard let ms = next.mediaTimeMs else { return nil }
        return .sharedPlayback(positionMs: snapshot.currentMediaTimeMs, nextMarginMs: ms)
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
        case .seekToLeadIn(let ms):
            if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: true) }
            dismissPendingImportedCommentary()
            seekMedia(toMediaTimeMs: ms)
        }
    }

    /// Goes to a friend's Margin and plays it, whether the listener asked from the card or the episode got there.
    private func playSharedMarginNow(_ prompt: ImportedCommentaryPrompt) {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: true) } // the episode comes back, so the jump reads it as playing
        dismissPendingImportedCommentary()
        guard jumpToImportedCommentary(interjectionID: prompt.interjection.id) else { return }
        listenToPendingImportedCommentary()
    }
}
