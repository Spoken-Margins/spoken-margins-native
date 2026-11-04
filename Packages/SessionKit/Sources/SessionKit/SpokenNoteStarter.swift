import Foundation

/// Where spoken notes live on disk, and how one is started (#3108, #1609).
///
/// Every note has a folder of its own under `SpokenNotes/` in Application Support: `note.json` (the takes, written by
/// `SpokenNoteStore`) beside the audio files the takes name. Nothing here touches the database; the Library item that
/// points at a note is built by `SpokenNoteItem`, and the app saves it like any other item.
public enum SpokenNoteStarter {
    public static let folderName = "SpokenNotes"

    /// What one tap on "start a spoken note" makes: the empty note (already on disk), its store, and its Library item.
    public struct Started: Sendable {
        public let note: SpokenNote
        public let store: SpokenNoteStore
        public let item: Item
    }

    public enum StartError: Error, Equatable, Sendable {
        /// Every id offered named a note that already exists. Nothing was overwritten.
        case noFreeNoteId
    }

    public static func notesRoot(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The store for a note id, or nil when the id could not be one folder name (empty, a path, `.` or `..`). An item's
    /// reference is data read back from the database or a packet, so it never gets to name a path outside the root.
    public static func store(noteId: String, in applicationSupport: URL) -> SpokenNoteStore? {
        guard isSafeNoteId(noteId) else { return nil }
        let folder = notesRoot(in: applicationSupport).appendingPathComponent(noteId, isDirectory: true)
        return SpokenNoteStore(folderURL: folder, noteId: noteId)
    }

    /// The store behind a Library item, or nil when the item is not a spoken note or names an unsafe id.
    public static func store(for item: Item, in applicationSupport: URL) -> SpokenNoteStore? {
        guard let noteId = SpokenNoteItem.noteId(of: item) else { return nil }
        return store(noteId: noteId, in: applicationSupport)
    }

    /// Makes a new, empty note: its folder and `note.json` on disk, and the Library item for it. A note that already
    /// exists is never touched; if `makeId` keeps offering ids of existing notes the start fails instead.
    public static func start(
        in applicationSupport: URL,
        now: Date,
        makeId: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> Started {
        let root = notesRoot(in: applicationSupport)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for _ in 0..<5 {
            let noteId = makeId()
            guard let store = store(noteId: noteId, in: applicationSupport) else { continue }
            // Not "intermediate": creating the folder fails if it is already there, so two starts that offer the same id
            // can't both win, and a folder that exists without a `note.json` is left alone too.
            do {
                try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: false)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            let note = SpokenNote(id: noteId)
            try store.save(note)
            return Started(note: note, store: store, item: SpokenNoteItem.makeItem(note: note, createdAt: now))
        }
        throw StartError.noFreeNoteId
    }

    /// Lowercase letters, digits, `-` and `_`, at most 100 of them: one plain folder name that means the same thing on
    /// a case- or Unicode-insensitive volume. Generated ids are lowercase UUIDs. A later slice that needs other ids (a
    /// packet's) widens this on purpose.
    static func isSafeNoteId(_ noteId: String) -> Bool {
        guard !noteId.isEmpty, noteId.utf8.count <= 100 else { return false }
        return noteId.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F }
    }
}
