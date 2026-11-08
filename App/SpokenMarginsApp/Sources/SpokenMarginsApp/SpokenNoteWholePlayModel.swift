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

    /// Plays the note: pauses or resumes it when it is already the open session, otherwise gets it ready and starts it.
    /// A note not played before starts at its beginning; one left part-way (or after a relaunch) continues where it
    /// stopped, as every other item does.
    /// - Parameter beforeStart: work to finish before the note takes the audio session (a sentence handing it back).
    func play(noteId: String, app: Gate1AppModel, beforeStart: (@MainActor () async -> Void)? = nil) {
        let itemId = SpokenNoteItem.itemId(forNoteId: noteId)
        let isOpenSession = app.hasActiveSession && app.snapshot.itemId == itemId && app.snapshot.phase != .finished
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
        Task {
            await beforeStart?()
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SpokenNoteWholePlayback.Prepared, Error> in
                do {
                    return .success(try await SpokenNoteWholePlayback.prepare(
                        store: noteStore, joiner: SpokenNoteAudioJoiner(), writer: store))
                } catch {
                    return .failure(error)
                }
            }.value
            isPreparing = false
            switch result {
            case .success(let prepared):
                timeline = prepared.timeline
                guard !isAbandoned else { return }
                let labels = MainThreadOperationLabels.shared // so a slow start names its step (#2256)
                labels.scoped("spokenNote.play") {
                    if isOpenSession, prepared.rebuilt {
                        // A take was added since this note was last played, so the paused session holds the older, shorter file.
                        app.startNewSession(id: itemId)
                    } else if isOpenSession {
                        app.playPause()
                    } else {
                        app.startItem(id: itemId)
                    }
                }
            case .failure(let error):
                message = Self.failureMessage(error)
            }
        }
    }

    /// Reads where the note's takes sit in the joined file, for a note whose audio was joined before (it may be playing
    /// now, or paused from earlier). A note never played has no joined file, and no timeline.
    func refreshTimeline(note: SpokenNote, noteFolder: URL) {
        Task {
            let found = await Task.detached(priority: .utility) {
                SpokenNoteWholePlayback.timeline(of: note, inFolder: noteFolder)
            }.value
            if found != timeline { timeline = found }
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
