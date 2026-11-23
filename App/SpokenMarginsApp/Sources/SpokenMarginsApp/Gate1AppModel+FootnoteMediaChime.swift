import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import UIKit

/// The footnotes of an article that plays its prepared audio as one file (#3777). Once every chunk is prepared, the
/// article plays that file through the media player, not the on-device voice, so the voice's chime never ran: in "Chime
/// where cited" its notes were read in full, with no tone and no card. `FootnoteMediaChimeSession` (SessionKit) decides;
/// this holds one for the file playing and applies its answers to the player.
@MainActor
final class FootnoteMediaChimeController {
    /// The session for the file playing, once built. Nil while it builds and for a file that reads no note where cited.
    var session: FootnoteMediaChimeSession?
    /// The item and file last built for, whether or not it had notes, so the tick does not build again.
    var builtFor: (itemId: String, mediaKey: String)?
    var buildTask: Task<Void, Never>?
    /// A Timeline tap on a note before its file's session was built (the item was not playing, or another one was): the
    /// note is read as soon as the session exists, if it is for that item and within `pendingLifetime`.
    var pendingNote: (label: String, itemId: String, at: TimeInterval)?
    static let pendingLifetime: TimeInterval = 10
    /// The next report comes from a boundary observer at a run's start, not the periodic tick.
    var boundaryReport = false
    let tone = FootnoteChimeCuePlayer()

    /// Forgets the session and takes its boundary times off `mediaClient`, the app's media player.
    func drop(mediaClient: AVPlayerStreamPlaybackClient?) {
        buildTask?.cancel()
        buildTask = nil
        if let builtFor { mediaClient?.setBoundaryTimes([], targetId: builtFor.mediaKey, handler: nil) }
        session = nil
        builtFor = nil
        boundaryReport = false
    }
}

extension Gate1AppModel {
    private var footnoteModeSetting: FootnoteMode {
        FootnoteMode(storedValue: UserDefaults.standard.string(forKey: FootnoteMode.storageKey))
    }

    /// The item and file of a prepared article playing as media, or nil for anything else. The file's identity is the
    /// target the engine plays it under (`nativeMediaId`, the file's URL).
    private func preparedFilePlayback(_ snapshot: SessionSnapshot) -> (itemId: String, mediaKey: String)? {
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue,
              snapshot.preparedTextAudioStatus == "ready",
              let itemId = snapshot.itemId, let mediaKey = snapshot.targetId else { return nil }
        return (itemId, mediaKey)
    }

    /// The session for the selected item's file while that file is the one playing or paused.
    var selectedItemFootnoteMediaSession: FootnoteMediaChimeSession? {
        guard snapshot.status.isPlaybackActive || snapshot.status == .paused,
              let playing = preparedFilePlayback(snapshot), playing.itemId == selectedItem.id,
              let session = footnoteMediaChime.session, session.plays(itemId: playing.itemId, mediaKey: playing.mediaKey) else { return nil }
        return session
    }

    /// Every playback tick, after the engine read the player's clock (`tickPlaybackProgress`).
    func observeFootnoteMediaChime(_ updated: SessionSnapshot) {
        let chime = footnoteMediaChime
        let boundary = chime.boundaryReport
        chime.boundaryReport = false
        guard let playing = preparedFilePlayback(updated) else {
            // Only another item ends the session: a friend's Margin or a reply played over this item changes the target
            // for a while, and the notes heard so far must not be offered again when the file goes on.
            if let builtFor = chime.builtFor, builtFor.itemId != updated.itemId { chime.drop(mediaClient: mediaPlaybackClient) }
            return
        }
        guard var session = chime.session, session.plays(itemId: playing.itemId, mediaKey: playing.mediaKey) else {
            buildFootnoteMediaChimeIfNeeded(itemId: playing.itemId, mediaKey: playing.mediaKey)
            return
        }
        guard updated.status.isPlaybackActive else {
            if updated.currentPlaybackProgressPercent >= ItemFinishedRule.atEndPercent { session.playedToEnd() }
            chime.session = session
            return
        }
        guard let timeMs = updated.currentMediaTimeMs else { return }
        let mode = footnoteModeSetting
        let active = UIApplication.shared.applicationState == .active
        let now = ProcessInfo.processInfo.systemUptime
        let action = boundary
            ? session.observeBoundary(timeMs: timeMs, mode: mode, appIsActive: active, now: now)
            : session.observe(timeMs: timeMs, mode: mode, appIsActive: active, now: now)
        chime.session = session
        switch action {
        case .none:
            break
        case .seek(let ms):
            moveForFootnote(toMediaTimeMs: ms, reason: "pass")
        case .cue(let label, let ms):
            let tone = chime.tone.play()
            recordDeveloperDiagnostic("footnote.media.cue", ["label": label, "tone": tone])
            moveForFootnote(toMediaTimeMs: ms, reason: "cue")
        }
    }

    /// Builds the session for a file off the main thread: the item's text, its timeline and the plan with note chunks.
    private func buildFootnoteMediaChimeIfNeeded(itemId: String, mediaKey: String) {
        let chime = footnoteMediaChime
        if let builtFor = chime.builtFor, builtFor.itemId == itemId, builtFor.mediaKey == mediaKey { return }
        chime.drop(mediaClient: mediaPlaybackClient)
        chime.builtFor = (itemId, mediaKey)
        guard let store else { return }
        chime.buildTask = Task { [weak self] in
            let built = try? await StoreReader(store).read { store in
                Self.loadFootnoteMediaChimeSession(store: store, itemId: itemId, mediaKey: mediaKey)
            }
            guard let self, !Task.isCancelled, let built,
                  let current = chime.builtFor, current.itemId == itemId, current.mediaKey == mediaKey else { return }
            hangTelemetry.labels.scoped("footnoteMediaSession") {
                chime.session = built
                self.mediaPlaybackClient?.setBoundaryTimes(built.runStartsMs, targetId: mediaKey) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.hangTelemetry.labels.scoped("footnoteBoundary") { self.footnoteMediaChimeBoundaryReached() }
                    }
                }
                recordDeveloperDiagnostic("footnote.media.session", ["runs": String(built.runStartsMs.count)])
                hearPendingFootnoteNote(itemId: itemId)
            }
        }
    }

    nonisolated static func loadFootnoteMediaChimeSession(
        store: SQLiteSessionStore, itemId: String, mediaKey: String
    ) -> FootnoteMediaChimeSession? {
        guard let item = try? store.loadItem(id: itemId), item.media?.sourceType == .generatedTTSPrerendered,
              item.media?.nativeMediaId == mediaKey || item.media?.url == mediaKey,
              let timeline = (try? store.loadTranscriptTimeline(itemId: itemId))?.timeline,
              let speech = PreparedSpeechHooks.texts.resolve(item: item, documents: store) else { return nil }
        // The file was assembled from the plan of `speech.text` (`finishBackgroundPreparedAudio`).
        return FootnoteMediaChimeSession(itemId: itemId, mediaKey: mediaKey, timeline: timeline, articleText: speech.text)
    }

    /// A boundary observer fired at the start of a run of notes: report now, not at the next tick.
    private func footnoteMediaChimeBoundaryReached() {
        guard footnoteMediaChime.session != nil, snapshot.status.isPlaybackActive else { return }
        footnoteMediaChime.boundaryReport = true
        tickPlaybackProgress()
    }

    /// A move the footnote session asked for: a plain engine seek, not the listener's, so a Margin moment or a Skim
    /// summary is not ended by it. Returns whether the engine took it.
    @discardableResult
    private func moveForFootnote(toMediaTimeMs ms: Int, reason: String) -> Bool {
        recordDeveloperDiagnostic("footnote.media.move", ["timeMs": String(ms), "reason": reason])
        let moved = run { engine in
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: ms)
            recordMediaSeekEvidence(from: engine)
        }
        if !moved { footnoteMediaChime.session?.playerMovedOnItsOwn() }
        return moved
    }

    // MARK: - The card's buttons and the Timeline

    /// The card's Hear note or Stop note on a prepared file. False when no media session answers, so the on-device
    /// voice's path runs instead.
    func footnoteMediaCardButtonPressed(_ button: FootnoteCardButton) -> Bool {
        guard selectedItemFootnoteMediaSession != nil else { return false }
        let ms: Int?
        switch button {
        case .hearNote: ms = footnoteMediaChime.session?.hearOfferedNote()
        case .stopNote: ms = footnoteMediaChime.session?.stopHearing()
        }
        if let ms { moveForFootnote(toMediaTimeMs: ms, reason: button == .hearNote ? "hear" : "stop") }
        return true
    }

    /// A Timeline tap on note `label` of the selected item: where its file reads it, when that file is playing and has
    /// a session. Nil otherwise; the caller then goes to the citing sentence, and `holdFootnoteNoteForMediaSession`
    /// keeps the request for a session that is not built yet.
    func footnoteMediaHearingStart(label: String, itemId: String) -> Int? {
        guard let session = selectedItemFootnoteMediaSession, session.itemId == itemId else { return nil }
        return footnoteMediaChime.session?.hearNote(label: label)
    }

    /// The Timeline tap's request, for a prepared file whose session is not built yet. It is kept for any article: only
    /// a prepared file's session for this item, built within `pendingLifetime`, reads it (`hearPendingFootnoteNote`).
    func holdFootnoteNoteForMediaSession(label: String, itemId: String) {
        guard selectedItem.id == itemId, !selectedItem.isNativeAudio else { return }
        footnoteMediaChime.pendingNote = (label, itemId, ProcessInfo.processInfo.systemUptime)
    }

    private func hearPendingFootnoteNote(itemId: String) {
        let chime = footnoteMediaChime
        guard let pending = chime.pendingNote else { return }
        chime.pendingNote = nil
        guard pending.itemId == itemId,
              ProcessInfo.processInfo.systemUptime - pending.at <= FootnoteMediaChimeController.pendingLifetime,
              footnoteModeSetting == .chime,
              let ms = chime.session?.hearNote(label: pending.label) else { return }
        moveForFootnote(toMediaTimeMs: ms, reason: "timeline")
    }
}
