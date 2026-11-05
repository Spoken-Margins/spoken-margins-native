import Foundation

/// Finds dictation that an ended app left outside its note (#3108).
///
/// A take is added to `note.json` only when its recording stops. If the app is force-quit, crashes or is ended by iOS
/// while a take runs, the take's audio file is in the note's folder but no take names it, and for a note's first take
/// there is no Library row either. At launch this adds every such file to its note as a take, and writes the row, so the
/// dictation can be reached. Nothing is deleted or rewritten: a file that will not open (a recording cut off before its
/// closing index) is still added, with no length, so it is kept and listed.
public enum SpokenNoteRecovery {
    /// A file touched this recently may still be a take being recorded; it is left for a later launch.
    public static let defaultQuietSeconds: TimeInterval = 60

    /// Returns the ids of the notes that gained a take.
    @discardableResult
    public static func recover(
        in applicationSupport: URL,
        now: Date,
        quietSeconds: TimeInterval = defaultQuietSeconds,
        measureDurationMs: (URL) -> Int,
        itemWriter: any SpokenNoteItemWriting
    ) -> [String] {
        let fileManager = FileManager.default
        let root = SpokenNoteStarter.notesRoot(in: applicationSupport)
        guard let folders = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var recovered: [String] = []
        for noteId in folders.sorted() {
            guard let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: store.folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let names = try? fileManager.contentsOfDirectory(atPath: store.folderURL.path) else { continue }
            let listed = Set(store.load().takes.map(\.audioFileName))
            var added = false
            for name in names.sorted() where name.hasPrefix("take-") && name.hasSuffix(".m4a") && !listed.contains(name) {
                let url = store.folderURL.appendingPathComponent(name)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                let modified = (attributes?[.modificationDate] as? Date) ?? now
                guard now.timeIntervalSince(modified) >= quietSeconds else { continue }
                let takeId = String(name.dropFirst("take-".count).dropLast(".m4a".count))
                do {
                    try SpokenNoteIntake.addRecordedTake(
                        audioFileName: name, durationMs: measureDurationMs(url), to: store, now: modified, takeId: takeId
                    )
                    added = true
                } catch {
                    // An unreadable note.json (or an unsafe name) is left alone; a later launch tries again.
                    continue
                }
            }
            guard added else { continue }
            let note = store.load()
            try? itemWriter.write(SpokenNoteItem.makeItem(note: note, createdAt: now), isFirstSave: true)
            recovered.append(noteId)
        }
        return recovered
    }
}
