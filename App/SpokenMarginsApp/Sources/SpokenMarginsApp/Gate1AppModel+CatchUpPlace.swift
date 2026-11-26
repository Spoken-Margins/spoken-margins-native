import Foundation
import SessionKit

/// The re-listen's place after a catch-up run (#5238). The run ends paused at the reply so "Add a Margin" anchors right
/// after it (#4785); the place the listener had re-listened to stays owed (`CatchUpPlace`, held on the run's review
/// note) and comes back on the next Play, Continue, another item, closing the player or a relaunch. Any move the
/// listener makes first drops it, and the 3 s test at every give-back is the backstop, so a missed route costs only the
/// old behaviour, never a wrong jump.
extension Gate1AppModel {
    /// The clock a review or catch-up run on the item on Now counts on (#5409): narration time for an article read aloud
    /// on the device, whose Margins are placed by characters, else the media's own time. The same choice "Play this
    /// moment" makes (#1577), so a review's places and the place it owes back are on one clock.
    var reviewSourceClock: MarginMomentClock {
        snapshot.targetType == TargetType.itemTextTTS.rawValue ? .liveNarration : .media
    }

    /// Where the source stands on `reviewSourceClock`: the playhead, or the narration time of the text being read.
    var reviewSourcePositionMs: Int? {
        let clock = reviewSourceClock
        guard clock.isNarratedText else { return snapshot.currentMediaTimeMs }
        return snapshot.currentTextStart.map(clock.position(forTextOffset:))
    }

    /// Moves the source to a place on `reviewSourceClock`, for a review's or catch-up run's place given back.
    @discardableResult
    func seekReviewSource(toPosition position: Int) -> Bool {
        let clock = reviewSourceClock
        guard clock.isNarratedText else { return seekMedia(toMediaTimeMs: position) }
        return seekText(toCharOffset: clock.textOffset(forPosition: position))
    }

    /// A held place for the item on Now that Play would give back now.
    var catchUpPlaceIsWaiting: Bool {
        guard let itemId = snapshot.itemId else { return false }
        if case .giveBack = CatchUpPlace.settle(
            reviewPlaces.owed(itemId: itemId), itemId: itemId, sourceAtMediaTimeMs: reviewSourcePositionMs) {
            return true
        }
        return false
    }

    /// Gives the held place back, or drops it when the source has moved since. True when it gave a place back. Nothing
    /// happens while a Margin moment runs: the run's own seeks, and a new moment's, are not the listener's Play. Only
    /// Play reports the jump (`reports`); leaving an item says nothing.
    @discardableResult
    func settleCatchUpPlace(trigger: String, reports: Bool = false) -> Bool {
        guard marginMomentConductor == nil, let itemId = snapshot.itemId else { return false }
        let note = reviewPlaces.owed(itemId: itemId)
        switch CatchUpPlace.settle(note, itemId: itemId, sourceAtMediaTimeMs: reviewSourcePositionMs) {
        case .nothing:
            return false
        case .drop:
            reviewPlaces.clear(itemId: itemId)
            diagnostics["catchUp.place"] = "dropped:\(trigger)"
            return false
        case .giveBack(let placeMs):
            reviewPlaces.clear(itemId: itemId) // first, so the seek's own `listenerMovedSource` finds nothing to drop
            guard seekReviewSource(toPosition: placeMs) else {
                diagnostics["catchUp.place"] = "give_back_failed"
                return false
            }
            marginCapture.forgetSharedReply() // a Margin at the listener's place doesn't answer the reply minutes back
            diagnostics["catchUp.place"] = "given_back:\(trigger)"
            if reports { reportSuccess("Back to where you were, \(MarginReplyWords.clock(milliseconds: placeMs)).") }
            return true
        }
    }

    /// The listener moved the source once the run was over (a scrub, a skip, a Skim landing, a jump, a Margin tapped to
    /// hear, Reply on a Margin): that is their place now, so the held one goes at once. During a run the note isn't held,
    /// so the run's own seeks never reach this.
    func dropHeldCatchUpPlace(trigger: String) {
        guard let itemId = snapshot.itemId, reviewPlaces.owed(itemId: itemId)?.heldAtMediaTimeMs != nil else { return }
        reviewPlaces.clear(itemId: itemId)
        diagnostics["catchUp.place"] = "dropped:\(trigger)"
    }

    /// Lock Screen, AirPods and CarPlay Play reach the engine without `resumePlayback`: called just before the compact
    /// dispatch, after every voice, commentary, Skim and recording guard, so a Play that only resumes a voice gives
    /// nothing back.
    func settleCatchUpPlaceBeforeCompactDispatch(_ command: CompactControlCommand) {
        guard CatchUpRun.Event.event(for: command, sourceIsPlaying: snapshot.status.isPlaybackActive) == .play else { return }
        settleCatchUpPlace(trigger: "compact", reports: true)
    }

    /// The note to hold again after a Margin saved while a place is owed: the save's rejoin moves the source a few
    /// seconds before the anchor, so the place is re-held where the source now stands and survives any number of saves.
    /// Read before the save; nil when no place is waiting.
    func catchUpPlaceToKeepThroughASave() -> ReviewReturnPlace? {
        guard catchUpPlaceIsWaiting, let itemId = snapshot.itemId else { return nil }
        return reviewPlaces.owed(itemId: itemId)
    }

    func keepCatchUpPlaceAfterASave(_ kept: ReviewReturnPlace?) {
        guard let kept, !snapshot.isRecording, snapshot.itemId == kept.itemId, let at = reviewSourcePositionMs else { return }
        reviewPlaces.owe(kept.held(at: at))
    }
}
