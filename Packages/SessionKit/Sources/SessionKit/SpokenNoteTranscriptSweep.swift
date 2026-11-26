import Foundation

/// Gives words to every take of a spoken note that has none (#4715). A take whose transcription met the Speech
/// Recognition hold is kept in its note with no words; this is how it gets them after Allow
/// (`HeldTranscription.Retry.spokenNoteSweep`), whether or not the note was ever opened again. A note with a recorder
/// open in this process is left to that recorder (`SpokenNoteLiveNotes`), as recovery leaves it. Nothing is deleted: a
/// take that still gets no words stays as it is, and the note's next open asks again.
public enum SpokenNoteTranscriptSweep {
    /// Transcribes each take with no words, note by note, files the words in and brings the note's Library row up to
    /// date (only its text; `SpokenNoteItemWriting`). Returns the ids of the notes that got words. File and database work
    /// runs on the caller's executor; the app calls it off the main thread.
    @discardableResult
    public static func fillMissingTranscripts(
        in applicationSupport: URL,
        transcriber: any SpokenNoteTranscribing,
        itemWriter: any SpokenNoteItemWriting,
        now: Date,
        liveNoteIds: Set<String> = SpokenNoteLiveNotes.ids()
    ) async -> [String] {
        let root = SpokenNoteStarter.notesRoot(in: applicationSupport)
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var filled: [String] = []
        for noteId in folders.sorted() where !liveNoteIds.contains(noteId) {
            guard let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else { continue }
            let waiting = store.load().takes.filter { !$0.hasTranscript }
            guard !waiting.isEmpty else { continue }
            var gotWords = false
            for take in waiting {
                let url = store.folderURL.appendingPathComponent(take.audioFileName)
                guard let words = try? await transcriber.transcribe(fileAt: url),
                      let note = try? SpokenNoteIntake.applyTranscript(words: words, forTake: take.id, in: store),
                      note.takes.first(where: { $0.id == take.id })?.hasTranscript == true else { continue }
                gotWords = true
            }
            guard gotWords else { continue }
            do {
                try itemWriter.write(SpokenNoteItem.makeItem(note: store.load(), createdAt: now), isFirstSave: !store.itemWasSaved)
                store.markItemSaved()
            } catch {
                // The words are safe in `note.json`; the row catches up the next time the note changes or opens.
            }
            filled.append(noteId)
        }
        return filled
    }
}
