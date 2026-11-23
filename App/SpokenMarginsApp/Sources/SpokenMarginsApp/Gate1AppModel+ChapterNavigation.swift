import Foundation
import SessionKit

/// Chapter jumps and play-from-start (#1011): moved out of `Gate1AppModel.swift` unchanged, to keep that
/// file under its size ceiling (scripts/hot_file_ratchet.py). Next chapter lives in `+NextChapter`.
extension Gate1AppModel {
    var nextPlaybackChapter: Chapter? {
        guard snapshot.itemId == selectedItem.id,
              snapshot.targetType == TargetType.itemTextTTS.rawValue,
              let index = selectedItem.chapters.firstIndex(where: { isCurrentTimelineChapter($0) }),
              selectedItem.chapters.indices.contains(index + 1) else { return nil }
        return selectedItem.chapters[index + 1]
    }

    var nextPlaybackMediaChapter: MediaTimelineChapter? {
        guard snapshot.itemId == selectedItem.id,
              snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue,
              let position = snapshot.currentMediaTimeMs else { return nil }
        let chapters = selectedItem.mediaChapters.isEmpty ? selectedItem.listeningMapScenes : selectedItem.mediaChapters
        return chapters.sorted { $0.startMs < $1.startMs }.first { $0.startMs > position }
    }

    func jumpToChapter(_ chapter: Chapter, fromTimeline: Bool = false) {
        jumpToEngineChapter(id: chapter.id, title: chapter.title, fromTimeline: fromTimeline)
    }

    func jumpToMediaChapter(_ chapter: MediaTimelineChapter, fromTimeline: Bool = false) {
        jumpToEngineChapter(id: chapter.id, title: chapter.title, fromTimeline: fromTimeline)
    }

    func jumpToListeningMapScene(_ scene: MediaTimelineChapter, fromTimeline: Bool = false) {
        navigateFromChapterControl(.jumpToChapter(scene.id, fromTimeline: fromTimeline), fromTimeline: fromTimeline, message: "Jumped to \(scene.title).") { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: scene.startMs)
            if !snapshot.status.isPlaybackActive {
                snapshot = try engine.resumePlayback()
            }
        }
    }

    func playSourceFromBeginning(fromTimeline: Bool = false) {
        navigateFromChapterControl(.playSourceFromBeginning(fromTimeline: fromTimeline), fromTimeline: fromTimeline, message: "Playing source from the beginning.") { engine in
            let startedSelectedItem = try ensureSessionForSelectedItem(engine)
            if !startedSelectedItem {
                snapshot = try engine.playSourceFromBeginning()
            }
        }
    }

    /// A Timeline row for a footnote was tapped (#3777, Design PR 7): go to the note, read it, and go on from the sentence
    /// after its citation, as the Footnote card's Hear note does. When the player holds this item's plan with notes in it,
    /// the move is that plan's own (`beginHearingFootnote`): the citing sentence's last chunk, then the note. Otherwise (the
    /// item was not playing, or its audio was prepared with the notes at the end) it goes to the start of the citing
    /// sentence, never to the citation itself: a seek at the place a note is cited means the text after the note. The
    /// narrator then reads the sentence and the note after it: in "Chime where cited" the client is told which note was
    /// asked for (`requestFootnoteHearing`), so the player reads it when it reaches it instead of offering it.
    func playFootnote(label: String, fromTimeline: Bool = false) {
        let mode = FootnoteMode(storedValue: UserDefaults.standard.string(forKey: FootnoteMode.storageKey))
        guard let note = FootnoteTimelineEntries.entry(label: label, for: selectedItem, readsWhereCited: mode.plansAsides) else {
            reportFailure("That footnote can't be found any more.")
            return
        }
        let itemId = activeItemId
        let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient
        navigateFromChapterControl(
            .playFootnote(label: label, fromTimeline: fromTimeline), fromTimeline: fromTimeline,
            message: "Playing \(note.title)."
        ) { engine in
            let startedSelectedItem = try ensureSessionForSelectedItem(engine)
            // A session just started has no plan to ask: the client learns the article when its first play begins.
            let hearing = startedSelectedItem ? nil : client?.beginHearingFootnote(label: label, targetId: itemId)
            let requested = hearing == nil && mode == .chime
            if requested { client?.requestFootnoteHearing(label: label, targetId: itemId) }
            synchronizeStreamingSpeechAnchorIfNeeded()
            do {
                snapshot = try engine.seekText(toCharOffset: hearing ?? note.sentenceStart)
            } catch {
                if hearing != nil || requested { client?.footnoteMoveFailed() }
                throw error
            }
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            // A seek on a paused session moves its place and plays nothing: the tap is a request to hear the note.
            if !snapshot.status.isPlaybackActive {
                snapshot = try engine.resumePlayback()
            }
        }
    }

    private func jumpToEngineChapter(id: String, title: String, fromTimeline: Bool) {
        navigateFromChapterControl(.jumpToChapter(id, fromTimeline: fromTimeline), fromTimeline: fromTimeline, message: "Jumped to \(title).") { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try engine.jumpToChapter(chapterId: id)
        }
    }

    /// The steps every chapter control shares (#1003): the Terms gate first, then stop previews and
    /// pending auto-play turns, then `move` inside `run`, then open Now Playing and report.
    private func navigateFromChapterControl(
        _ action: PendingPlaybackAfterTerms,
        fromTimeline: Bool,
        message: String,
        fileID: String = #fileID,
        line: Int = #line,
        move: (SessionEngine) throws -> Void
    ) {
        guard !requireTermsDecisionBeforePlayback(action) else { return }
        restoreSkimOriginBeforeCanonicalTransport() // a chapter tap ends a Skim summary instead of being undone by it (#1471)
        stopSpeechPreviews()
        marginMomentConductor?.sourceMoved() // a chapter jump over a Margin doesn't play it (#1656)
        clearPendingAutoPlayTurns()
        run(fileID: fileID, line: line) { engine in
            try move(engine)
            refreshSelectedItemAfterTransport()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess(message)
        }
    }

    /// Item Detail can be opened while another item remains in the mini player. Chapter
    /// actions belong to the item being viewed, not merely to whichever session happens
    /// to be restored in the engine.
    @discardableResult
    private func ensureSessionForSelectedItem(_ engine: SessionEngine) throws -> Bool {
        try prepareSourceMediaPlayback(itemId: activeItemId)
        if let session = engine.currentSession, session.itemId == activeItemId,
           SessionContinuation.continueResumes(session) {
            return false
        }
        resetMixWithOtherAudioForNewSession()
        if engine.currentSession != nil {
            snapshot = try endEngineSession(engine, reason: .chapterActionSwitchItem)
        }
        let started = try engine.startSession(itemId: activeItemId)
        snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
        return true
    }
}
