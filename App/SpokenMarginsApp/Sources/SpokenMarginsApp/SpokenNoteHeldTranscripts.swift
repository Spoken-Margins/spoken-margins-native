import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// The spoken notes' launch work and their sweep after Allow (#3108, #4715). It is its own type so the model does not
/// grow: the model hands it the store once at launch (`Gate1AppModel.recoverSpokenNotes`).
///
/// A spoken note take whose transcription met the Speech Recognition hold is kept in its note with no words. The gate
/// reports the hold to the speech ask, which owes the card and, after Allow, calls `transcribeMissing`: every note's
/// takes with no words are transcribed off the main thread (`SpokenNoteTranscriptSweep`).
@MainActor
enum SpokenNoteHeldTranscripts {
    private struct Environment {
        let applicationSupport: URL
        let store: SQLiteSessionStore
        let libraryChanged: @MainActor () -> Void
    }

    private static var environment: Environment?
    /// Allow came before the launch handed over the store: the sweep runs as soon as it does.
    private static var sweepWaitingForStore = false

    /// At launch: adds dictation that an ended app left outside its note (a force-quit during a take) to that note and
    /// the Library, off the main thread, and keeps the store for the sweep after Allow. Quick when there is nothing to
    /// find: it lists one folder.
    static func start(applicationSupport: URL, store: SQLiteSessionStore, libraryChanged: @escaping @MainActor () -> Void) {
        environment = Environment(applicationSupport: applicationSupport, store: store, libraryChanged: libraryChanged)
        Task.detached(priority: .utility) {
            let recovered = SpokenNoteRecovery.recover(
                in: applicationSupport, now: Date(),
                measureDurationMs: { SpokenNoteAudioFile.durationMs(of: $0) },
                itemWriter: store
            )
            guard !recovered.isEmpty else { return }
            await MainActor.run { libraryChanged() }
        }
        if sweepWaitingForStore {
            sweepWaitingForStore = false
            transcribeMissing()
        }
    }

    /// After Allow: transcribes every spoken note take that has no words, off the main thread, and refreshes the Library
    /// rows when any note got words.
    static func transcribeMissing() {
        guard let environment else {
            sweepWaitingForStore = true
            return
        }
        let support = environment.applicationSupport
        let store = environment.store
        let libraryChanged = environment.libraryChanged
        Task.detached(priority: .utility) {
            let filled = await SpokenNoteTranscriptSweep.fillMissingTranscripts(
                in: support, transcriber: SystemSpokenNoteTranscriber(), itemWriter: store, now: Date()
            )
            guard !filled.isEmpty else { return }
            await MainActor.run {
                MainThreadOperationLabels.shared.scoped("spokenNote.heldTranscriptsFilled") { libraryChanged() }
            }
        }
    }
}
