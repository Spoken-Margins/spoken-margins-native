import Foundation
import SessionKit

/// Skim goes to the next chapter or Margin, whichever comes first (#460). The ordering is `SkimStops` and the choice
/// between a stop and the scene summary is `SkimStopRouting`, both in SessionKit. This reads the playing item's
/// chapters and Margins into them and carries out the press, through the playback paths that already exist: the
/// chapter jumps, and the Margin moment ("Play this moment", #159) for a Margin, whose lead-in a second press skips.
/// It keeps no state of its own: the running Margin moment is the only memory a second press needs. It sits in its own
/// file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// The playing item's stops, or nil when Skim has no source (a recording, no store, not a media or text item).
    private var skimStopList: SkimStops? {
        guard let source = skimSource, selectedItem.id == source.itemId else { return nil }
        let itemId = source.itemId
        let usesText = source.usesTextPositions
        let unit: SkimStops.PositionUnit = usesText
            ? .characters(perSecond: ListeningTimeEstimator.defaultCharactersPerSecond) : .milliseconds
        let own = marginRows.map(\.interjection).filter { $0.itemId == itemId && $0.isSpokenItemMargin }
        var layerIsEligible: [String: Bool] = [:] // once per layer, not once per Margin
        let shared = sharedMarginRows.filter { row in
            guard row.layer.itemId == itemId, row.interjection.audioPath != nil else { return false }
            if let known = layerIsEligible[row.layer.id] { return known }
            let eligible = Self.isImportedCommentaryLayerPlaybackEligible(
                row.layer, records: selectedItem.importedCommentaryInterjections[row.layer.id] ?? [])
            layerIsEligible[row.layer.id] = eligible
            return eligible
        }.map(\.interjection)
        return SkimStopRouting.stops(
            textChapters: selectedItem.chapters,
            mediaChapters: selectedItem.mediaChapters.isEmpty ? selectedItem.listeningMapScenes : selectedItem.mediaChapters,
            ownMargins: own, sharedMargins: shared, unit: unit)
    }

    func skimStopChoice(direction: SkimDirection, at position: Int, summaryDestination: Int?) -> SkimStopRouting.Choice {
        let target: SkimStops.Target?
        if let stops = skimStopList {
            target = direction == .forward
                ? stops.next(playhead: position, leadInMs: MarginMomentSequence.defaultLeadInMs)
                : stops.previous(playhead: position, leadInMs: MarginMomentSequence.defaultLeadInMs)
        } else {
            target = nil
        }
        return SkimStopRouting.choose(direction: direction, stop: target, summaryDestination: summaryDestination)
    }

    func skimMomentPress(direction: SkimDirection) -> SkimStopRouting.MomentPress {
        SkimStopRouting.press(direction: direction, moment: SkimStopRouting.MomentState(marginMoment, positionMs: marginMomentPositionMs))
    }

    func skimRunMomentPress(_ press: SkimStopRouting.MomentPress) {
        switch press {
        case .navigate: break
        case .playMarginNow: playMarginMomentNow()
        case .skipVoice: skipMarginMomentVoice()
        case .endMomentThenNavigate:
            // A voice that was sounding had paused the source: bringing it back is the moment's to do (#1538).
            if endMarginMomentVoiceIfPlaying() { resumePlayback() } else { endMarginMoment() }
        }
    }

    func skimGo(to target: SkimStops.Target) {
        guard let itemId = skimSource?.itemId else { return }
        // A friend's Margin that is sounding or waiting gives way: the stop is where the listener is going now.
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        dismissPendingImportedCommentary()
        let stop = target.stop
        switch stop.kind {
        case .chapter: goToSkimChapter(id: stop.id)
        case .margin:
            let playhead = skimCurrentMediaTimeMs ?? 0
            let started = startSkimMargin(id: stop.id, itemId: itemId)
            if started {
                // Already inside the lead-in window: never seek back (and replay the Margin before it); play it now.
                if SkimStopRouting.startAction(playhead: playhead, target: target) == .playNow { playMarginMomentNow() }
            } else {
                // The Margin could not start. Move to it anyway, so the next press goes on to the stop after it
                // instead of meeting this one again.
                if isTextReadingSnapshot { seekText(toCharOffset: stop.position) } else { seekMedia(toMediaTimeMs: stop.position) }
            }
        }
    }

    private func goToSkimChapter(id: String) {
        if let chapter = selectedItem.chapters.first(where: { $0.id == id }), isTextReadingSnapshot {
            jumpToChapter(chapter)
        } else if let chapter = selectedItem.mediaChapters.first(where: { $0.id == id }) {
            jumpToMediaChapter(chapter)
        } else if let scene = selectedItem.listeningMapScenes.first(where: { $0.id == id }) {
            jumpToListeningMapScene(scene)
        }
    }

    /// A Margin stop starts that Margin's moment: a lead-in, then the Margin inline, then the source carries on.
    /// False when nothing started.
    private func startSkimMargin(id: String, itemId: String) -> Bool {
        if let row = marginRows.first(where: { $0.interjection.id == id && $0.interjection.itemId == itemId }) {
            return playMarginMoment(row)
        }
        guard let row = sharedMarginRows.first(where: { $0.interjection.id == id && $0.layer.itemId == itemId }) else { return false }
        if isTextReadingSnapshot {
            // Text read aloud has no lead-in to seek to: a friend's Margin goes straight to it (#3220).
            guard let prompt = importedCommentaryPrompts(includeAnnounced: true).first(where: { $0.interjection.id == id }) else { return false }
            playSharedMarginNow(prompt)
            return true
        }
        playSharedMarginMoment(row) // reports its own failures and starts no moment then
        return marginMoment != nil
    }
}
