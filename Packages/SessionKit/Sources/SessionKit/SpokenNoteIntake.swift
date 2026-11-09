import Foundation

/// How a finished recording and its transcript get into a spoken note (#3108, #1609).
///
/// The recorder writes the take's audio file into the note's folder; the transcriber finishes later. So a take is
/// added the moment its audio is safe on disk, with no transcript, and the transcript is filled in when it arrives.
/// If the transcriber never finishes, the audio is still in the note and nothing dictated is lost. Both steps read
/// the note from its store, change it and write it back. Each is one short step under one process-wide lock, so two
/// screens on the same note (one finishing a transcript while the note is opened again) can't write over each other.
public enum SpokenNoteIntake {
    private static let changeLock = NSLock()

    public enum IntakeError: Error, Equatable, Sendable {
        /// The audio file name is not one plain file name inside the note's folder.
        case unsafeAudioFileName
        /// The named audio file is not in the note's folder, so a take would point at nothing.
        case audioFileMissing
        /// The note was never started: its folder is not there.
        case noteNotFound
        /// `note.json` is there but could not be read just now (a locked phone, say). Saving would write over the
        /// earlier dictation with only this change, so nothing is saved; the caller tries again later.
        case noteUnreadable
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
        guard isRegularFile(store.folderURL.appendingPathComponent(audioFileName)) else { throw IntakeError.audioFileMissing }
        changeLock.lock()
        defer { changeLock.unlock() }
        var note = try loadForChange(store)
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
        changeLock.lock()
        defer { changeLock.unlock() }
        var note = try loadForChange(store)
        let sentences = SpokenNoteSentenceGrouping.sentences(from: words)
        if note.setTranscript(sentences, forTake: takeId) { try store.save(note) }
        return note
    }

    /// `item` with its text brought up to date with `note`, so a build that doesn't know spoken notes still shows the
    /// transcript. Nothing else about the item changes, and an item that isn't this note's is returned as it was.
    public static func updatedItem(_ item: Item, for note: SpokenNote) -> Item {
        guard SpokenNoteItem.noteId(of: item) == note.id, item.text != note.text else { return item }
        var updated = item
        // A made-up title follows the words; one the listener typed, or an older note's, is left as it is (#3663).
        if SpokenNoteTitle.isAutomatic(item) {
            updated.title = SpokenNoteTitle.automatic(createdAt: item.createdAt, text: note.text)
        }
        updated.text = note.text
        return updated
    }

    /// The note to change. A missing `note.json` is an empty note, as in `SpokenNoteStore.load`; one that is there
    /// but cannot be read is an error, never an empty note that the next save would write over it.
    private static func loadForChange(_ store: SpokenNoteStore) throws -> SpokenNote {
        if FileManager.default.fileExists(atPath: store.fileURL.path), (try? Data(contentsOf: store.fileURL)) == nil {
            throw IntakeError.noteUnreadable
        }
        return store.load()
    }

    /// A regular file, not a folder and not a link to something elsewhere.
    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// One plain file name: not empty, no separators, not `.` or `..`, and not the note's own file or its set-aside copies.
    public static func isPlainFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 200, name != ".", name != ".." else { return false }
        // Printable ASCII only, so no lookalike separator or letter ("ſ" folds to "s" on a case-insensitive volume)
        // can name another file; the app's own recorder only makes plain names.
        guard name.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), !name.contains("/"), !name.contains("\\") else { return false }
        let lower = name.lowercased()
        return !(lower.hasPrefix("note.") && lower.hasSuffix(".json"))
    }
}
