import Foundation
import SessionKit
import SessionKitAudio

/// Moving a spoken note between As recorded and Shorter pauses (#4779). The two files run on different clocks, so a
/// change never swaps the file under a running session: the old session is set aside and a new one starts at the same
/// moment of the recording on the other file (`SessionEngine.restartSpokenNote`). The screen, the sleep timer and the
/// rest of the app stay as they are. Margins are saved on the recording's clock either way (`SpokenNoteCleanClock`).
extension Gate1AppModel {
    /// Whether a version change must wait: a take or Margin being recorded, a written Margin open, a skim open, or a
    /// Margin (rather than the note) playing each hold the session where it is.
    var spokenNoteVersionChangeIsBlocked: Bool {
        recordingNavigationIsLocked || spokenNoteClean.takeIsRecording || skimBridgeState != nil
            || (hasActiveSession && snapshot.phase != .itemPlayback)
    }

    /// The open session plays this note (not one of its Margins).
    func spokenNoteIsOpenSession(noteId: String) -> Bool {
        hasActiveSession && snapshot.itemId == SpokenNoteItem.itemId(forNoteId: noteId) && snapshot.phase != .finished
            && snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
    }

    /// What became of a version change asked for the open session.
    enum SpokenNoteSwitchOutcome {
        /// Done, or nothing to do (the note isn't open, or already plays that version).
        case settled
        /// Held by a recording, a skim or a Margin playing; ask again when it clears.
        case blocked
    }

    /// Prepares `version` for the note and, when the note is the open session on the other version, attaches it and
    /// starts the note again on it at the same moment, playing or paused as it was. Nothing is attached unless the
    /// restart follows, so the item never names one file while the session plays the other.
    func switchSpokenNoteVersion(noteId: String, to version: SpokenNoteAudioVersion) async -> SpokenNoteSwitchOutcome {
        guard spokenNoteIsOpenSession(noteId: noteId) else { return .settled }
        guard !spokenNoteVersionChangeIsBlocked else { return .blocked }
        guard let store, let support = try? applicationSupportDirectory(),
              let noteStore = SpokenNoteStarter.store(noteId: noteId, in: support) else { return .settled }
        let prepared = await Task.detached(priority: .userInitiated) {
            try? await SpokenNoteWholePlayback.prepare(
                store: noteStore, joiner: SpokenNoteAudioJoiner(), writer: store, version: version, attach: false)
        }.value
        // The listener may have moved on, begun a recording, or chosen again while the file was read.
        guard let prepared, spokenNoteClean.version == version, spokenNoteIsOpenSession(noteId: noteId) else { return .settled }
        guard !spokenNoteVersionChangeIsBlocked else { return .blocked }
        restartSpokenNoteIfVersionChanged(prepared: prepared, playing: snapshot.status.isPlaybackActive)
        return .settled
    }

    /// For the open session's note: when `prepared` is the other version, attaches it and restarts the note on it at
    /// the same moment. Returns false when it is the version already playing (nothing is attached or restarted).
    @discardableResult
    func restartSpokenNoteIfVersionChanged(prepared: SpokenNoteWholePlayback.Prepared, playing: Bool) -> Bool {
        guard let startMs = SpokenNoteVersionPlan.switchStartMs(
            playingMs: snapshot.currentMediaTimeMs ?? 0,
            previousMediaURL: engine?.currentItem?.media?.url,
            newMediaURL: prepared.audioURL.absoluteString
        ), let store else { return false }
        do {
            try SpokenNoteWholePlayback.attach(prepared, writer: store)
        } catch {
            reportFailure(error, context: "Changing the note's audio failed")
            return true
        }
        let itemId = prepared.itemId
        _ = run { engine in
            try prepareSourceMediaPlayback(itemId: itemId)
            let restarted = try engine.restartSpokenNote(atMediaTimeMs: startMs, playing: playing)
            snapshot = try applyPreferredPlaybackRate(to: restarted, engine: engine)
            if selectedItem.id == itemId { selectedItem = try loadItemDetail(id: itemId, store: store) }
        }
        return true
    }

    /// For a note with a saved session (not open now) whose place was kept on the other version's clock: the place on
    /// the prepared file, or nil when the saved session is on the same version or there is none to carry on.
    func spokenNoteSavedPlaceOnNewVersion(itemId: String, previousMediaURL: String?, prepared: SpokenNoteWholePlayback.Prepared) -> Int? {
        guard let store, let sessions = try? store.loadSessions(itemId: itemId),
              case .resume(let session) = PlayRule.startAction(sessions: sessions, addedAgainAt: addedAgainAt(forItem: itemId)) else { return nil }
        return SpokenNoteVersionPlan.switchStartMs(
            playingMs: session.position.mediaTimeMs ?? 0,
            previousMediaURL: previousMediaURL,
            newMediaURL: prepared.audioURL.absoluteString
        )
    }

    /// The note's saved sessions are set aside (their places are on the other version's clock) and the note starts at
    /// `atMs` on the file now attached, through the normal start, so the screen moves to Now as any Play does.
    func startSpokenNoteSession(itemId: String, atMs: Int) {
        if let store, let sessions = try? store.loadSessions(itemId: itemId) {
            for var session in sessions where SessionContinuation.isResumableSession(session) {
                session.phase = .abandoned
                try? store.saveSession(session)
            }
        }
        spokenNoteClean.setPendingStart(itemId: itemId, ms: atMs)
        startNewSession(id: itemId)
        _ = spokenNoteClean.takePendingStartMs(itemId: itemId) // a start that was refused leaves nothing for a later one
    }

    /// A start of a spoken note from anywhere but its Play control (the Library's Continue, a relaunch) whose item names
    /// the version the listener didn't choose: it goes through the Play control's path, which attaches the chosen one.
    /// Returns true when it took the start over.
    func startSpokenNoteThroughChosenVersion(itemId: String) -> Bool {
        if spokenNoteClean.routingItemId == itemId { spokenNoteClean.routingItemId = nil; return false } // the routed start itself
        guard itemId.hasPrefix(SpokenNoteItem.itemId(forNoteId: "")), let store, // only a note's item reads the row
              let summary = try? store.loadItemSummary(id: itemId), SpokenNoteItem.isSpokenNote(mediaType: summary.mediaType),
              let noteId = SpokenNoteItem.noteId(fromReference: summary.externalReference),
              let support = try? applicationSupportDirectory(),
              let noteStore = SpokenNoteStarter.store(noteId: noteId, in: support) else { return false }
        guard SpokenNoteVersionPlan.startNeedsAttach(
            chosen: spokenNoteClean.version, mediaURL: summary.media?.url, noteFolder: noteStore.folderURL
        ) else {
            spokenNoteClean.notePlaybackStarted(noteId: noteId)
            return false
        }
        spokenNoteClean.routeStart(noteId: noteId, itemId: itemId, app: self)
        return true
    }
}
