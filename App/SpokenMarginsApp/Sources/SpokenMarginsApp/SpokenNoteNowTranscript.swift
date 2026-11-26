import Foundation
import SessionKit

extension Notification.Name {
    /// A spoken note's file changed: a take was saved, or its words were written down (#4780). Posted from the recorder's
    /// Library refresh, so an open Now re-reads the note and its words replace the no-words card by themselves.
    static let spokenNoteChanged = Notification.Name("SpokenMargins.spokenNoteChanged")
}

/// The words a spoken note shows on Now, read off the main actor from the note itself (`note.json` and the joined
/// audio's layout), never from the Library item's text, which can be stale (#4780).
///
/// It only reads: `peek()`, never `load()`, so an unreadable file is never moved aside from here.
@MainActor
final class SpokenNoteNowTranscript: ObservableObject {
    @Published private(set) var availability: SpokenNoteNowPassage.Availability = .loading
    @Published private(set) var words: SpokenNoteNowPassage.Words?
    /// Moves only when the note or its timeline differ from the last read, so a reload with nothing new keeps the
    /// scene's scroll and follow state.
    @Published private(set) var revision = 0

    private struct Result: Sendable {
        let availability: SpokenNoteNowPassage.Availability
        let words: SpokenNoteNowPassage.Words?
    }

    /// The last read of each note opened in this run. The playback screen is built again on every open and while a
    /// Margin is recorded, so without it the words would pop in each time. Memory only, one entry per note and file
    /// clock, so words timed for one version are never shown for the other; a stale entry is replaced by the read that
    /// always follows.
    private static var lastResult: [String: Result] = [:]

    private static func cacheKey(noteId: String, playingMediaURL: String?) -> String {
        guard let playingMediaURL, SpokenNoteCleanFiles.namesCleanAudio(playingMediaURL) else { return noteId }
        return "\(noteId) \(playingMediaURL)"
    }

    /// The note `availability` and `words` belong to. The screen shows them only for the note it has selected, so a
    /// change of item never draws the last note's words for a pass.
    private(set) var noteId: String?
    private var requests = 0

    /// Reads the note named by an item's reference. A reference that is no note clears to `.loading` with no words.
    /// - Parameter playingMediaURL: the file the open session plays when it is this note, else nil. The rows' times are
    ///   on that file's clock, so the caller loads again when it changes.
    /// - Parameter applicationSupport: where the notes live: the app passes `model.applicationSupportDirectory`, a
    ///   test a temporary folder. A throw reads as no words.
    func load(externalReference: String?, playingMediaURL: String? = nil, applicationSupport: () throws -> URL) {
        requests += 1
        let request = requests
        guard let noteId = SpokenNoteItem.noteId(fromReference: externalReference) else {
            self.noteId = nil
            publish(Result(availability: .loading, words: nil))
            return
        }
        let key = Self.cacheKey(noteId: noteId, playingMediaURL: playingMediaURL)
        if self.noteId != noteId {
            self.noteId = noteId
            // Another note: start from its last read, or Loading, never from the previous note's words.
            publish(Self.lastResult[key] ?? Result(availability: .loading, words: nil))
        }
        let store: SpokenNoteStore?
        do {
            store = SpokenNoteStarter.store(noteId: noteId, in: try applicationSupport())
        } catch {
            store = nil
        }
        guard let store else {
            finish(Result(availability: .noWords, words: nil), noteId: noteId, key: key, request: request)
            return
        }
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { () -> Result in
                let note = store.peek()
                let availability = SpokenNoteNowPassage.Availability(note: note)
                guard let note, availability != .noWords else { return Result(availability: availability, words: nil) }
                return Result(availability: availability, words: SpokenNoteNowPassage.Words(
                    note: note, inFolder: store.folderURL, playingMediaURL: playingMediaURL))
            }.value
            self?.finish(read, noteId: noteId, key: key, request: request)
        }
    }

    private func finish(_ result: Result, noteId: String, key: String, request: Int) {
        // Reads can finish out of order, or for a note no longer shown: only the newest request's answer is kept, in the
        // cache too, so an older read finishing last never replaces a newer one.
        guard request == requests, self.noteId == noteId else { return }
        Self.lastResult[key] = result
        publish(result)
    }

    private func publish(_ result: Result) {
        if availability != result.availability { availability = result.availability }
        guard words != result.words else { return }
        words = result.words
        revision &+= 1
    }
}
