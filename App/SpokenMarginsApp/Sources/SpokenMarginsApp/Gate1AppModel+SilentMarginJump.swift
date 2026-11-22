import Foundation
import SessionKit

/// Going to a friend's Margin that is never read aloud (#4934). Such a Margin (reading off by the sender or the listener, no
/// voice here that can read it, or no readable words) is still a place: the Margins tab, the Now tab's Nearby Margins, the
/// Timeline, "Where people reacted", the Library and the details sheet all go through `goToSharedMargin`, so they cannot
/// drift apart. The source moves to the Margin's place and plays on, nothing is spoken and no tone plays, and the pinned
/// card on Now shows the Margin's words (`SilentMarginLanding`). It sits in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// The one go-to for a friend's Margin from a list. A Margin that has a voice takes today's path: its moment, or, for a
    /// passage of the open item's text, the passage and then the Margin (`playSharedMarginFromMarginsList`). A Margin that
    /// is never read aloud moves the source to its place and plays on.
    func goToSharedMargin(_ row: SharedMarginRow) {
        guard !SharedMarginAudio.canOffer(row.interjection) else { return playSharedMarginFromMarginsList(row) }
        goToSilentSharedMargin(row)
    }

    /// The landing, while the card for it should still show: the source is still this item and its place is within the
    /// landing's window (`SilentMarginLanding.isShowing`). A read of the playhead and nothing else, so it needs no timer and is
    /// right at any playback speed, for a listener who pauses, and after a scrub away.
    var shownSilentMarginLanding: SilentMarginLanding? {
        guard let landing = silentMarginLanding, landing.itemId == snapshot.itemId else { return nil }
        let playhead: Int?
        switch landing.unit {
        case .milliseconds: playhead = snapshot.currentMediaTimeMs
        case .characters: playhead = snapshot.currentTextStart
        }
        guard let playhead, landing.isShowing(playhead: playhead) else { return nil }
        return landing
    }

    /// "Dismiss" on the card: the card goes, the source keeps playing.
    func dismissSilentMarginLanding() {
        silentMarginLanding = nil
    }

    private func goToSilentSharedMargin(_ row: SharedMarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("go_to_shared_margin") else { return }
        guard let itemID = row.layer.itemId else {
            return reportFailure("The source for this shared Margin isn't in your Library.")
        }
        guard SharedMarginListPlay.canGo(row.interjection, in: row.layer), let place = SharedMarginReplyPlace(row.interjection) else {
            return reportFailure("This shared Margin has no position in the episode.")
        }
        // Whatever of a friend's is sounding, waiting or running gives way: this is where the listener is going now (`skimGo`).
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        dismissPendingImportedCommentary()
        endMarginMoment(); stopInterjectionAudioPlayback()
        silentMarginLanding = nil
        if snapshot.itemId != itemID || !hasActiveSession { startItem(id: itemID) }
        guard snapshot.itemId == itemID else { return }
        guard let landing = SilentMarginLanding(
            going: row.interjection, in: row.layer, itemId: itemID,
            textUnit: .characters(perSecond: ListeningTimeEstimator.defaultCharactersPerSecond)) else { return }
        let moved: Bool
        switch place {
        case .media(let timeMs): moved = seekMedia(toMediaTimeMs: timeMs)
        case .text(let charOffset): moved = seekText(toCharOffset: charOffset)
        }
        guard moved else { return } // the seek reported why; no card for a place the source didn't reach
        if !snapshot.status.isPlaybackActive { resumePlayback() }
        silentMarginLanding = landing
        // Landing is how a note reading was turned off for is met (the details sheet's own rule, #3427). One with no voice on
        // this phone stays unmarked (#3402): a voice downloaded later still has it to read.
        let margin = row.interjection
        if margin.isWritten, margin.isNewToListener, !margin.readAloudChoice { markSharedMarginHeard(margin) }
        screen = .playback
        showNowRequests += 1 // the playback screen switches to Now, where the card is
    }
}
