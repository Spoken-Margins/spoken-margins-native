import Foundation
import SessionKit
import SessionKitAudio
import SwiftUI

/// Play for a whole spoken note (#3662): makes the note playable off the main thread, then hands it to the same playback
/// the app uses for every item with its own audio. It holds no player and no position of its own. Now, the Lock
/// Screen, headphones, skip back and resume after a relaunch are the shared engine's, so this only gets the note ready
/// (the takes joined into one file, the item pointed at it) and presses Play.
///
/// The note's own screen and the Library's rows each own one.
@MainActor
final class SpokenNoteWholePlayModel: ObservableObject {
    /// The takes are being joined. Seconds for a long note the first time, nothing after.
    @Published private(set) var isPreparing = false
    /// A plain line for a play that could not start, for an alert or the note screen's message line.
    @Published var message: String?
    /// The note's sentences on the joined audio's clock, once known. The note screen reads it to light the sentence that is
    /// sounding and to jump to one.
    @Published private(set) var timeline: SpokenNoteWholeTimeline?

    /// The screen that asked has gone: a play that finishes now does not start anything.
    private var isAbandoned = false
    private var timelineRequests = 0

    /// Plays the note: pauses or resumes it when it is already the open session, otherwise gets it ready and starts it.
    /// A note not played before starts at its beginning; one left part-way (or after a relaunch) continues where it
    /// stopped, as every other item does.
    /// - Parameters:
    ///   - beforeStart: work to finish before the note takes the audio session (a sentence handing it back).
    ///   - shouldStart: asked once the note is ready, so a screen that has since begun recording (which the join's seconds
    ///     allow) is not played over: when it says no, nothing starts.
    ///   - ifNotReady: for a start routed here from elsewhere (the Library's Continue, a relaunch), what to do instead of
    ///     showing a message when the note can't be got ready: that start goes on with the file the item names.
    func play(
        noteId: String, app: Gate1AppModel,
        beforeStart: (@MainActor () async -> Void)? = nil, shouldStart: (@MainActor () -> Bool)? = nil,
        ifNotReady: (@MainActor () -> Void)? = nil
    ) {
        let itemId = SpokenNoteItem.itemId(forNoteId: noteId)
        let isOpenSession = app.hasActiveSession && app.snapshot.itemId == itemId && app.snapshot.phase != .finished
            && app.snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
        // Pause is at once. Nothing can have been added to a note that is playing (recording pauses it first).
        if isOpenSession, app.snapshot.status.isPlaybackActive {
            app.playPause()
            return
        }
        guard !isPreparing else { return }
        guard let store = app.store, let support = try? app.applicationSupportDirectory(),
              let noteStore = SpokenNoteStarter.store(noteId: noteId, in: support) else {
            message = "This note's recordings aren't on this phone."
            return
        }
        isPreparing = true
        isAbandoned = false
        message = nil
        let version = app.spokenNoteClean.version
        // The open session's file, read from memory now: a version change under it restarts from this file's clock.
        let openMediaURL = isOpenSession ? app.openSessionMediaURL : nil
        Task {
            await beforeStart?()
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Ready, Error> in
                do {
                    // The file attached before, so a note whose version changed since its last play starts at the same
                    // moment on the new one instead of carrying on with a place on the other clock (#4779). Both clocks
                    // and the saved sessions are read here, off the main thread.
                    let previous = isOpenSession ? openMediaURL : (try? store.loadItemSummary(id: itemId))?.media?.url
                    let prepared = try await SpokenNoteWholePlayback.prepare(
                        store: noteStore, joiner: SpokenNoteAudioJoiner(), writer: store, version: version, attach: false)
                    let plan = SpokenNoteVersionSwitch.plan(previousMediaURL: previous, newMediaURL: prepared.audioURL.absoluteString)
                    let sessions = plan != nil && !isOpenSession ? ((try? store.loadSessions(itemId: itemId)) ?? []) : []
                    return .success(Ready(prepared: prepared, plan: plan, savedSessions: sessions))
                } catch {
                    return .failure(error)
                }
            }.value
            isPreparing = false
            switch result {
            case .success(let ready):
                let prepared = ready.prepared
                timelineRequests += 1
                timeline = prepared.timeline
                guard !isAbandoned, shouldStart?() ?? true else { return }
                // Chosen again while the file was read: get the newly chosen one ready instead (#4779).
                guard app.spokenNoteClean.version == version else {
                    play(noteId: noteId, app: app, shouldStart: shouldStart, ifNotReady: ifNotReady)
                    return
                }
                // The open note was moved to the other file while this one was read: the plan is for a file no longer
                // playing, so read again from where it is now.
                guard !isOpenSession || app.openSessionMediaURL == openMediaURL else {
                    play(noteId: noteId, app: app, shouldStart: shouldStart, ifNotReady: ifNotReady)
                    return
                }
                let labels = MainThreadOperationLabels.shared // so a slow start names its step (#2256)
                // A note not open now whose saved place is on the other version's clock: its sessions are set aside off
                // the main thread first, and the file is attached only after that, right before the start (below).
                if !isOpenSession, let startMs = Self.savedPlaceOnNewVersion(ready, addedAgainAt: app.addedAgainAt(forItem: itemId)) {
                    let sessionBefore = app.snapshot.sessionId
                    await app.setAsideSpokenNoteSessions(itemId: itemId)
                    // The listener may have closed the screen, started something else or chosen again meanwhile.
                    guard !isAbandoned, shouldStart?() ?? true, app.spokenNoteClean.version == version,
                          app.snapshot.sessionId == sessionBefore else { return }
                    labels.scoped("spokenNote.playOnNewVersion") {
                        do {
                            try SpokenNoteWholePlayback.attach(prepared, writer: store)
                        } catch {
                            message = Self.failureMessage(error)
                            return
                        }
                        app.startSpokenNoteSession(itemId: itemId, atMs: startMs)
                    }
                    app.spokenNoteClean.notePlaybackStarted(noteId: noteId)
                    return
                }
                labels.scoped("spokenNote.play") {
                    // A version change under the open session attaches its file itself, right before the restart.
                    if isOpenSession, !prepared.rebuilt,
                       app.restartSpokenNote(prepared: prepared, plan: ready.plan, playing: true) { return }
                    do {
                        try SpokenNoteWholePlayback.attach(prepared, writer: store)
                    } catch {
                        message = Self.failureMessage(error)
                        return
                    }
                    if isOpenSession, prepared.rebuilt {
                        // A take was added since this note was last played, so the paused session holds the older, shorter file.
                        app.startNewSession(id: itemId)
                    } else if isOpenSession {
                        app.playPause()
                    } else {
                        app.spokenNoteClean.routingItemId = itemId // this start already has the chosen version
                        app.startItem(id: itemId)
                    }
                }
                app.spokenNoteClean.notePlaybackStarted(noteId: noteId)
            case .failure(let error):
                if let ifNotReady, !isAbandoned {
                    ifNotReady()
                } else {
                    message = Self.failureMessage(error)
                }
            }
        }
    }

    /// What the off-main read hands back: the prepared file, the move onto it when it is the other version, and, for a
    /// note not open now, its saved sessions when that move happens.
    private struct Ready: Sendable {
        let prepared: SpokenNoteWholePlayback.Prepared
        let plan: SpokenNoteVersionSwitch?
        let savedSessions: [Session]
    }

    /// For a note with a saved session (not open now) whose place was kept on the other version's clock: the place on
    /// the prepared file, or nil when the file is the same version or there is no session to carry on.
    private static func savedPlaceOnNewVersion(_ ready: Ready, addedAgainAt: Date?) -> Int? {
        guard let plan = ready.plan,
              case .resume(let session) = PlayRule.startAction(sessions: ready.savedSessions, addedAgainAt: addedAgainAt) else { return nil }
        return plan.startMs(playingMs: session.position.mediaTimeMs ?? 0)
    }

    /// Reads where the note's takes sit in the joined file, for a note whose audio was joined before (it may be playing
    /// now, or paused from earlier). A note never played has no joined file, and no timeline.
    func refreshTimeline(note: SpokenNote, noteFolder: URL) {
        timelineRequests += 1
        let request = timelineRequests
        Task {
            let found = await Task.detached(priority: .utility) {
                SpokenNoteWholePlayback.timeline(of: note, inFolder: noteFolder)
            }.value
            // Reads can finish out of order: only the newest request's answer is kept.
            if request == timelineRequests, found != timeline { timeline = found }
        }
    }

    /// The screen is closing: a play still getting ready does not start once it is.
    func abandon() {
        isAbandoned = true
    }

    private static func failureMessage(_ error: Error) -> String {
        switch error {
        case SpokenNoteWholePlayback.PrepareError.noteUnreadable:
            return "This note can't be read right now, so it can't be played. Nothing was changed."
        case SpokenNoteWholePlayback.PrepareError.noAudio:
            return "This note has no audio on this phone to play."
        case SpokenNoteWholePlayback.PrepareError.itemGone:
            return "This note isn't in your Library, so it can't be played."
        default:
            return "Couldn't get this note ready to play. Your recordings are still on your phone."
        }
    }
}

extension View {
    /// Tells the listener why a note would not play, on screens that have no message line of their own.
    func spokenNotePlayFlow(_ play: SpokenNoteWholePlayModel) -> some View {
        alert(
            "Can't play this note",
            isPresented: Binding(get: { play.message != nil }, set: { if !$0 { play.message = nil } }),
            presenting: play.message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { text in
            Text(text)
        }
    }
}

/// Shown over the Library while a note's takes are being joined for its first play.
struct SpokenNotePlayProgress: View {
    var body: some View {
        ProgressView("Getting it ready…")
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("spokenNote.playProgress")
    }
}
