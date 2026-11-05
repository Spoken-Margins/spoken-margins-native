import Foundation

/// The notes that have a recorder open in this process (#3108). Recovery leaves their folders alone.
public enum SpokenNoteLiveNotes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var open: [String: Int] = [:]

    public static func add(_ noteId: String) { lock.withLock { open[noteId, default: 0] += 1 } }

    public static func remove(_ noteId: String) {
        lock.withLock {
            open[noteId, default: 1] -= 1
            if open[noteId, default: 0] <= 0 { open[noteId] = nil }
        }
    }

    public static func ids() -> Set<String> { lock.withLock { Set(open.keys) } }
}

/// Finds dictation that an ended app left outside its note (#3108).
///
/// A take is added to `note.json` only when its recording stops. If the app is force-quit, crashes or is ended by iOS
/// while a take runs, the take's audio file is in the note's folder but no take names it, and for a note's first take
/// there is no Library row either. At launch this adds every such file to its note as a take, and writes the row, so the
/// dictation can be reached. Nothing is deleted or rewritten: a file that will not open (a recording cut off before its
/// closing index) is still added, with no length, so it is kept and listed.
public enum SpokenNoteRecovery {
    /// Returns the ids of the notes that gained a take.
    @discardableResult
    public static func recover(
        in applicationSupport: URL,
        now: Date,
        measureDurationMs: (URL) -> Int,
        itemWriter: any SpokenNoteItemWriting,
        liveNoteIds: Set<String> = SpokenNoteLiveNotes.ids()
    ) -> [String] {
        let fileManager = FileManager.default
        let root = SpokenNoteStarter.notesRoot(in: applicationSupport)
        guard let folders = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var recovered: [String] = []
        for noteId in folders.sorted() {
            // A note with a recorder open in this process is never touched: its file is being written right now. At launch
            // there is none, so no time window is needed to tell a cut-off take from a live one.
            guard !liveNoteIds.contains(noteId),
                  let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: store.folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let names = try? fileManager.contentsOfDirectory(atPath: store.folderURL.path) else { continue }
            let existing = store.load().takes
            let listed = Set(existing.map(\.audioFileName))
            var added = false
            for name in names.sorted() where name.hasPrefix("take-") && name.hasSuffix(".m4a") && !listed.contains(name) {
                let url = store.folderURL.appendingPathComponent(name)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                let modified = (attributes?[.modificationDate] as? Date) ?? now
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
            // The row is made for a note whose row was never written: no take before, or none recorded that the row was
            // saved (the first save failed and the app ended during a later take). A row that was written and since
            // deleted by the listener is not made again.
            let isFirstSave = existing.isEmpty || !store.itemWasSaved
            do {
                try itemWriter.write(SpokenNoteItem.makeItem(note: note, createdAt: now), isFirstSave: isFirstSave)
                store.markItemSaved()
            } catch {
                // Not saved now; the marker stays absent, so the next launch offers the row again.
            }
            recovered.append(noteId)
        }
        return recovered
    }
}
