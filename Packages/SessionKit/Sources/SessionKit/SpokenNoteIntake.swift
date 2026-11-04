import Foundation

/// How a finished recording and its transcript get into a spoken note (#3108, #1609).
///
/// The recorder writes the take's audio file into the note's folder; the transcriber finishes later. So a take is
/// added the moment its audio is safe on disk, with no transcript, and the transcript is filled in when it arrives.
/// If the transcriber never finishes, the audio is still in the note and nothing dictated is lost. Both steps read
/// the note from its store, change it and write it back, so the caller runs them one at a time per note (the app's
/// recorder does: one recording at a time, and a transcript is applied on the same queue).
public enum SpokenNoteIntake {
    public enum IntakeError: Error, Equatable, Sendable {
        /// The audio file name is not one plain file name inside the note's folder.
        case unsafeAudioFileName
        /// The named audio file is not in the note's folder, so a take would point at nothing.
        case audioFileMissing
        /// The note was never started: its folder is not there.
        case noteNotFound
    }

    /// Adds a take for `audioFileName`, which must already be in the note's folder, at the end of the note. A take
    /// whose id is already there is not added twice (the note comes back unchanged), so a save that runs again after
    /// a crash can't double it.
    @discardableResult
    public static func addRecordedTake(
        audioFileName: String,
        durationMs: Int,
        to store: SpokenNoteStore,
        now: Date,
        takeId: String = UUID().uuidString.lowercased()
    ) throws -> SpokenNote {
        guard isPlainFileName(audioFileName) else { throw IntakeError.unsafeAudioFileName }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: store.folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IntakeError.noteNotFound
        }
        guard FileManager.default.fileExists(atPath: store.folderURL.appendingPathComponent(audioFileName).path) else {
            throw IntakeError.audioFileMissing
        }
        var note = store.load()
        let take = SpokenNoteTake(id: takeId, audioFileName: audioFileName, durationMs: durationMs, createdAt: now)
        if note.appendTake(take) { try store.save(note) }
        return note
    }

    /// Fills in the transcript of a take from the transcriber's timed words. A take that already has a transcript
    /// keeps it, an unknown take changes nothing, and so do words that hold no text. Returns the note as saved.
    @discardableResult
    public static func applyTranscript(
        words: [AlignedTranscriptSegment],
        forTake takeId: String,
        in store: SpokenNoteStore
    ) throws -> SpokenNote {
        var note = store.load()
        let sentences = SpokenNoteSentenceGrouping.sentences(from: words)
        if note.setTranscript(sentences, forTake: takeId) { try store.save(note) }
        return note
    }

    /// `item` with its text brought up to date with `note`, so a build that doesn't know spoken notes still shows the
    /// transcript. Nothing else about the item changes, and an item that isn't this note's is returned as it was.
    public static func updatedItem(_ item: Item, for note: SpokenNote) -> Item {
        guard SpokenNoteItem.noteId(of: item) == note.id, item.text != note.text else { return item }
        var updated = item
        updated.text = note.text
        return updated
    }

    /// One plain file name: not empty, no separators, not `.` or `..`, and not the note's own file or its set-aside copies.
    static func isPlainFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 200, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return false }
        return !name.lowercased().hasPrefix("note.") || !name.lowercased().hasSuffix(".json")
    }
}
