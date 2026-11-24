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
        guard let landing = silentMarginLanding, !landing.isDismissed, landing.itemId == snapshot.itemId else { return nil }
        guard let playhead = silentMarginLandingPlayhead, landing.isShowing(playhead: playhead) else { return nil }
        return landing
    }

    /// The source's place in the landing's own unit (a media time, or a character offset), nil with no landing or no place.
    var silentMarginLandingPlayhead: Int? {
        silentMarginLanding.flatMap { playhead(in: $0.unit) }
    }

    private func playhead(in unit: SkimStops.PositionUnit) -> Int? {
        switch unit {
        case .milliseconds: return snapshot.currentMediaTimeMs
        case .characters: return snapshot.currentTextStart
        }
    }

    /// "Dismiss" on the card: the card goes, the source keeps playing. The landing stays, marked dismissed, so a Skim press a moment
    /// later still never lands on the stop the listener is at (`SilentMarginLanding.skimTarget`).
    func dismissSilentMarginLanding() {
        silentMarginLanding = silentMarginLanding?.dismissed()
    }

    private func goToSilentSharedMargin(_ row: SharedMarginRow) {
        guard !rejectNavigationOrSessionMutationWhileRecording("go_to_shared_margin") else { return }
        guard let itemID = row.layer.itemId else {
            return reportFailure("The source for this shared Margin isn't in your Library.")
        }
        guard SharedMarginListPlay.canGo(row.interjection, in: row.layer), SharedMarginReplyPlace(row.interjection) != nil else {
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
        guard land(on: landing, friend: row) else { return } // the seek reported why; no card for a place the source didn't reach
        screen = .playback
        showNowRequests += 1 // the playback screen switches to Now, where the card is
    }

    /// A Skim press that went to a silent Margin stop (#4934): the source moves to the stop's place and plays on, nothing is
    /// spoken, and the card on Now says what is there. The same landing steps as a list's go-to, on the open item, with no
    /// switch of screen: the press came from where Skim is. It ends no voice of its own: `skimGo` already gave way to a friend's.
    func goToSilentSkimStop(_ stop: SkimStop, itemId: String) {
        // The listener's own written Margin (#4938): the landing gathers the notes just after it, so a burst takes one press.
        if stop.isOwnWritten {
            guard let stops = skimStopList, let landing = SilentMarginLanding(
                own: stop, in: stops, margins: ownWrittenSkimMargins(itemId: itemId), itemId: itemId) else { return }
            land(on: landing, friend: nil)
            return
        }
        guard let source = skimSource, let row = sharedMarginRows.first(where: { $0.interjection.id == stop.id && $0.layer.itemId == itemId })
        else { return }
        let unit: SkimStops.PositionUnit = source.usesTextPositions
            ? .characters(perSecond: ListeningTimeEstimator.defaultCharactersPerSecond) : .milliseconds
        guard let landing = SilentMarginLanding(skipping: stop, margin: row.interjection, in: row.layer, itemId: itemId, unit: unit)
        else { return }
        land(on: landing, friend: row)
    }

    /// A go-to on the listener's own written Margin from a list (the Margins tab, the details sheet, the Timeline, the Library) that
    /// already moved the source there (`MarginMomentTap`, #4938). It sets the same landing a Skim press would, with no seek, so the
    /// card says "Your Margin is here" and the next Skim press never lands on this note again. Nothing for a spoken Margin, another
    /// item, or a source that did not end up inside the landing's window.
    func landOnOwnWrittenMargin(_ row: MarginRow) {
        let margin = row.interjection
        guard SilentMarginWords.ownWrittenGoesTo(margin), skimSource != nil, snapshot.itemId == margin.itemId else { return }
        silentMarginLanding = nil // a go-to elsewhere ends any landing from before
        guard let stops = skimStopList else { return }
        let landing: SilentMarginLanding
        if let stop = stops.stops.first(where: { $0.kind == .margin && $0.id == margin.id && $0.isOwnWritten }),
           let gathered = SilentMarginLanding(own: stop, in: stops, margins: ownWrittenSkimMargins(itemId: margin.itemId), itemId: margin.itemId) {
            landing = gathered
        } else if let place = SkimStop.margin(margin, unit: stops.unit) {
            // Dropped from the list on a tie with another stop: a landing of its own, at the same place.
            landing = SilentMarginLanding(own: margin, position: place.position, itemId: margin.itemId, unit: stops.unit)
        } else {
            return
        }
        // The go-to may have played from a narration or sentence time that differs from the anchor: no card for a place elsewhere.
        guard let playhead = playhead(in: landing.unit), landing.isShowing(playhead: playhead) else { return }
        silentMarginLanding = landing
    }

    /// Seek to the landing's place, play on, show its card and, for a friend's Margin when the details sheet's own rule says so, mark
    /// it heard (a note reading was turned off for is met by landing, #3427; one with no voice on this phone stays unmarked, #3402: a
    /// voice downloaded later still has it to read). The listener's own note (`friend` nil) has nothing to mark. False when the seek
    /// did not move the source, which reported why.
    @discardableResult
    private func land(on landing: SilentMarginLanding, friend row: SharedMarginRow?) -> Bool {
        let moved: Bool
        switch landing.unit {
        case .milliseconds: moved = seekMedia(toMediaTimeMs: landing.position)
        case .characters: moved = seekText(toCharOffset: landing.position)
        }
        guard moved else { return false }
        if !snapshot.status.isPlaybackActive { resumePlayback() }
        silentMarginLanding = landing
        guard let margin = row?.interjection else { return true }
        if margin.isWritten, margin.isNewToListener, !margin.readAloudChoice { markSharedMarginHeard(margin) }
        return true
    }
}
