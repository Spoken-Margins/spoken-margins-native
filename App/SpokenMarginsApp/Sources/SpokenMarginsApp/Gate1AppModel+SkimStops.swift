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
        let own = marginRows.lazy.map(\.interjection).filter { $0.itemId == itemId && $0.isSpokenItemMargin }
        let shared = sharedMarginRows.lazy.filter { row in
            row.layer.itemId == itemId && row.interjection.audioPath != nil
                && Self.isImportedCommentaryLayerPlaybackEligible(
                    row.layer, records: self.selectedItem.importedCommentaryInterjections[row.layer.id] ?? [])
        }.map(\.interjection)
        return SkimStopRouting.stops(
            textChapters: selectedItem.chapters,
            mediaChapters: selectedItem.mediaChapters.isEmpty ? selectedItem.listeningMapScenes : selectedItem.mediaChapters,
            ownMargins: Array(own), sharedMargins: Array(shared), unit: unit)
    }

    func skimStopChoice(direction: SkimDirection, at position: Int, summaryDestination: Int?) -> SkimStopRouting.Choice {
        let target: SkimStops.Target?
        if let stops = skimStopList {
            target = direction == .forward ? stops.next(playhead: position) : stops.previous(playhead: position)
        } else {
            target = nil
        }
        return SkimStopRouting.choose(direction: direction, stop: target, summaryDestination: summaryDestination)
    }

    func skimMomentPress(direction: SkimDirection) -> SkimStopRouting.MomentPress {
        SkimStopRouting.press(direction: direction, moment: SkimStopRouting.MomentState(marginMoment))
    }

    func skimRunMomentPress(_ press: SkimStopRouting.MomentPress) {
        switch press {
        case .navigate: break
        case .playMarginNow: playMarginMomentNow()
        case .skipVoice: skipMarginMomentVoice()
        case .endMomentThenNavigate: endMarginMoment()
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
        case .margin: startSkimMargin(id: stop.id, itemId: itemId)
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
    private func startSkimMargin(id: String, itemId: String) {
        if let row = marginRows.first(where: { $0.interjection.id == id && $0.interjection.itemId == itemId }) {
            playMarginMoment(row)
        } else if let row = sharedMarginRows.first(where: { $0.interjection.id == id && $0.layer.itemId == itemId }) {
            if isTextReadingSnapshot {
                // Text read aloud has no lead-in to seek to: a friend's Margin goes straight to it (#3220).
                if let prompt = importedCommentaryPrompts(includeAnnounced: true).first(where: { $0.interjection.id == id }) {
                    playSharedMarginNow(prompt)
                }
            } else {
                playSharedMarginMoment(row)
            }
        }
    }
}
