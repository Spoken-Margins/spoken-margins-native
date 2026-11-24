import Foundation
import SessionKit
import SessionKitAudio

/// Moving a spoken note between As recorded and Shorter pauses (#4779). The two files run on different clocks, so a
/// change never swaps the file under a running session: the old session is set aside and a new one starts at the same
/// moment of the recording on the other file (`SessionEngine.restartSpokenNote`). The screen, the sleep timer and the
/// rest of the app stay as they are. Margins are saved on the recording's clock either way (`SpokenNoteCleanClock`).
extension Gate1AppModel {
    /// Whether a version change must wait: a take or Margin being recorded, a written Margin open, a skim open, or a
    /// Margin (rather than the note) playing each hold the session where it is. A finished session holds nothing.
    var spokenNoteVersionChangeIsBlocked: Bool {
        recordingNavigationIsLocked || spokenNoteClean.takeIsRecording || skimBridgeState != nil
            || (hasActiveSession && SpokenNoteVersionPlan.phaseHoldsVersionChange(snapshot.phase))
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

    /// The file the open session plays now, as the item named it when the session started. Read from memory.
    var openSessionMediaURL: String? { engine?.currentItem?.media?.url }

    /// Prepares `version` for the note and, when the note is the open session on the other version, attaches it and
    /// starts the note again on it at the same moment, playing or paused as it was. Nothing is attached unless the
    /// restart follows, so the item never names one file while the session plays the other. The file and both clocks
    /// are read off the main thread; the restart itself is one engine transition, as any Play is.
    func switchSpokenNoteVersion(noteId: String, to version: SpokenNoteAudioVersion) async -> SpokenNoteSwitchOutcome {
        guard spokenNoteIsOpenSession(noteId: noteId) else { return .settled }
        guard !spokenNoteVersionChangeIsBlocked else { return .blocked }
        guard let store, let support = try? applicationSupportDirectory(),
              let noteStore = SpokenNoteStarter.store(noteId: noteId, in: support) else { return .settled }
        let previousMediaURL = openSessionMediaURL
        let ready = await Task.detached(priority: .userInitiated) { () -> (SpokenNoteWholePlayback.Prepared, SpokenNoteVersionSwitch?)? in
            guard let prepared = try? await SpokenNoteWholePlayback.prepare(
                store: noteStore, joiner: SpokenNoteAudioJoiner(), writer: store, version: version, attach: false) else { return nil }
            return (prepared, SpokenNoteVersionSwitch.plan(previousMediaURL: previousMediaURL, newMediaURL: prepared.audioURL.absoluteString))
        }.value
        // The listener may have moved on, begun a recording, or chosen again while the file was read.
        guard let ready, spokenNoteClean.version == version, spokenNoteIsOpenSession(noteId: noteId) else { return .settled }
        let (prepared, plan) = ready
        guard !spokenNoteVersionChangeIsBlocked else { return .blocked }
        // Another restart moved the session while the file was read: the plan is for a file no longer playing. Read again.
        guard openSessionMediaURL == previousMediaURL else { return .blocked }
        hangTelemetry.labels.scoped("spokenNote.switchVersion") {
            _ = restartSpokenNote(prepared: prepared, plan: plan, playing: snapshot.status.isPlaybackActive)
        }
        return .settled
    }

    /// For the open session's note: when `plan` moves it to the other version (it is nil when `prepared` is the version
    /// already playing), attaches `prepared` and restarts the note on it at the same moment. Returns false when there
    /// was nothing to move (nothing is attached or restarted). Returns true, with nothing attached, when the session
    /// moved off the plan's file while it was read: the caller must not attach `prepared` under it either.
    @discardableResult
    func restartSpokenNote(prepared: SpokenNoteWholePlayback.Prepared, plan: SpokenNoteVersionSwitch?, playing: Bool) -> Bool {
        guard let plan else { return false }
        guard plan.previousMediaURL == openSessionMediaURL, let store else { return true }
        let startMs = plan.startMs(playingMs: snapshot.currentMediaTimeMs ?? 0)
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

    /// The note's saved sessions are set aside, off the main thread: their places are on the other version's clock, so
    /// none of them may be continued once the other file is attached.
    func setAsideSpokenNoteSessions(itemId: String) async {
        guard let store else { return }
        _ = try? await Self.offMain {
            for var session in try store.loadSessions(itemId: itemId) where SessionContinuation.isResumableSession(session) {
                session.phase = .abandoned
                try store.saveSession(session)
            }
        }
    }

    /// Starts the note at `atMs` on the file now attached, through the normal start, so the screen moves to Now as any
    /// Play does. Call it after `setAsideSpokenNoteSessions`.
    func startSpokenNoteSession(itemId: String, atMs: Int) {
        spokenNoteClean.setPendingStart(itemId: itemId, ms: atMs)
        startNewSession(id: itemId)
        _ = spokenNoteClean.takePendingStartMs(itemId: itemId) // a start that was refused leaves nothing for a later one
    }

    /// A start of a spoken note from anywhere but its Play control (the Library's Continue, a relaunch) whose item names
    /// the version the listener didn't choose: it goes through the Play control's path, which prepares the chosen one
    /// off the main thread and attaches it when it can play (a Shorter pauses version not made yet leaves the recording
    /// attached, and the start goes on as before). Returns true when it took the start over. The open session's note
    /// is never routed: moving it between versions is the coordinator's (`switchSpokenNoteVersion`).
    func startSpokenNoteThroughChosenVersion(itemId: String) -> Bool {
        if spokenNoteClean.routingItemId == itemId { spokenNoteClean.routingItemId = nil; return false } // the routed start itself
        guard itemId.hasPrefix(SpokenNoteItem.itemId(forNoteId: "")), let store, // only a note's item reads the row
              let summary = try? store.loadItemSummary(id: itemId), SpokenNoteItem.isSpokenNote(mediaType: summary.mediaType),
              let noteId = SpokenNoteItem.noteId(fromReference: summary.externalReference) else { return false }
        guard !spokenNoteIsOpenSession(noteId: noteId),
              SpokenNoteVersionPlan.attachedVersion(mediaURL: summary.media?.url) != spokenNoteClean.version else {
            spokenNoteClean.notePlaybackStarted(noteId: noteId)
            return false
        }
        spokenNoteClean.routeStart(noteId: noteId, itemId: itemId, app: self)
        return true
    }
}
