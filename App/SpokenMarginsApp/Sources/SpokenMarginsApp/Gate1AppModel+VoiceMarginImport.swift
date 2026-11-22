import Foundation
import SessionKit
import SessionKitPersistence

/// The Add Voice Margin Shortcuts action (#4924) saving a recording it already holds (`VoiceMarginImport`) as a spoken
/// Margin. Where the Margin goes is `AddVoiceMarginAction`'s; these two put it on an item. Both leave the words to the
/// ordinary transcription, which runs after the save and never holds it up.
extension Gate1AppModel {
    /// Saves `audioPath` as a spoken Margin on `itemId`'s saved session, at its saved place, while whatever is playing
    /// carries on (`StoredSessionMargin.addSpoken`). Returns the title of the item that received it. Throws
    /// `StoredSessionMargin.Failure` before writing anything when the item isn't in the Library or has no session.
    func addVoiceMarginToStoredItem(id itemId: String, audioPath: String) throws -> String {
        guard let store else { throw StoredSessionMargin.Failure.itemNotFound }
        let saved = try StoredSessionMargin.addSpoken(audioPath: audioPath, itemId: itemId, repository: store)
        voiceMarginSaved(saved.interjection)
        return saved.itemTitle
    }

    /// Saves `audioPath` as a spoken Margin on the item in the player, at the place it has now, through the same
    /// capture the written Margin uses, so the source is paused for the save and put back as the listener left it.
    /// Returns the item's title. Throws before touching playback when nothing is playing or a Margin is being written.
    func addVoiceMarginToPlayer(audioPath: String) throws -> String {
        guard hasActiveSession else { throw AddMarginShortcutError.nothingRunning }
        guard !recordingNavigationIsLocked else { throw AddMarginShortcutError.writingInProgress }
        beginWrittenMargin()
        guard let draft = writtenMarginDraft, let engine else {
            throw AddMarginShortcutError.notSaved(lastError)
        }
        do {
            snapshot = try engine.saveSpokenInterjection(captureId: draft.capture.id, audioRef: audioPath)
        } catch {
            // Nothing was saved (the engine keeps the capture open when it refuses): close the draft so the next run starts clean.
            let reason = ListenerErrorText.message(for: error)
            cancelWrittenMargin()
            throw AddMarginShortcutError.notSaved(reason)
        }
        marginCapture.closeDraft()
        clearWrittenMarginJournal(captureId: draft.capture.id)
        if draft.priorWasPlaying { streamingSpeechQueue.resumeAfterInterjection() }
        // The Margin is saved from here on. A read that can't find it only costs its words and its signal, never the save.
        if let id = engine.lastScheduledTranscriptionInterjectionId,
           let saved = (try? store?.loadInterjections(sessionId: draft.capture.sessionId))?.first(where: { $0.id == id }) {
            voiceMarginSaved(saved)
        } else {
            refreshMarginRowsInBackground(forItem: draft.capture.itemId)
            refreshSelectedItemInBackground()
        }
        return draft.itemTitle
    }

    /// What follows a saved voice Margin: its words are asked for, the listening signal is counted, and the lists
    /// that show Margins are brought up to date.
    private func voiceMarginSaved(_ interjection: Interjection) {
        scheduleTranscription(for: interjection)
        listeningSignals.spokenMargin(
            sessionId: interjection.sessionId, interjectionId: interjection.id, itemId: interjection.itemId,
            audioURL: interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:))
        )
        refreshMarginRowsInBackground(forItem: interjection.itemId)
        if activeItemId == interjection.itemId { refreshSelectedItemInBackground() }
    }
}
