import Foundation
import SessionKit

/// The one place a transcript file becomes a Library item (#2997). Files, Quick Folder, Open In, the share drain and,
/// later, inbound email all call it, so one rule decides what a file is, what it is called and what id it gets.
///
/// Reading, parsing, building and the store write all run off the caller's actor, in order, so two imports of the
/// same file at once (a double AirDrop, or Files and the share sheet together) give one item and never interleave.
public enum TranscriptLibraryImport {
    public enum Outcome: Equatable, Sendable {
        /// The item is in the Library. `readded` when it was already there or in Recently Deleted. `title` is the item's own,
        /// which on an add again is the one the listener may have changed.
        case added(itemId: String, title: String, readded: Bool)
        /// Not a transcript: the decoded text, for the caller to import as ordinary text, or to refuse for a `.docx`.
        case notTranscript(text: String)
        /// A file that can't be added, with the sentence to show.
        case failed(TranscriptImportMessage)
    }

    /// The order key every transcript import shares.
    public static let orderKey = "transcript-import"

    /// `docxText` reads a Word file's text (`DocxPlainText` lives in `SessionKitEPUB`, which depends on this module).
    /// Throws only what the store throws, so a caller that keeps a hand-off for a failed save can tell it from a refusal.
    public static func importFile(
        name: String,
        data: Data,
        store: SQLiteSessionStore,
        docxText: @escaping @Sendable (Data) throws -> String,
        now: Date = Date(),
        stillListeningItemIds: Set<String> = [],
        timeZone: TimeZone = .current
    ) async throws -> Outcome {
        try await StoreReader(store).readInOrder(orderKey) { store in
            switch TranscriptFileRouter.route(fileName: name, data: data, docxText: docxText, timeZone: timeZone) {
            case .failed(let message): return .failed(message)
            case .notTranscript(let text): return .notTranscript(text: text)
            case .transcript(let transcript):
                return try save(transcript, name: name, store: store, now: now, stillListeningItemIds: stillListeningItemIds, timeZone: timeZone)
            }
        }
    }

    /// For text that was already decoded (the share drain). The same rule as a `.txt` file.
    public static func importText(
        name: String,
        text: String,
        store: SQLiteSessionStore,
        now: Date = Date(),
        stillListeningItemIds: Set<String> = [],
        timeZone: TimeZone = .current
    ) async throws -> Outcome {
        try await StoreReader(store).readInOrder(orderKey) { store in
            guard let transcript = TranscriptFileRouter.isTranscript(text: text, timeZone: timeZone) else {
                return .notTranscript(text: text)
            }
            return try save(transcript, name: name, store: store, now: now, stillListeningItemIds: stillListeningItemIds, timeZone: timeZone)
        }
    }

    private static func save(
        _ transcript: ImportedTranscript,
        name: String,
        store: SQLiteSessionStore,
        now: Date,
        stillListeningItemIds: Set<String>,
        timeZone: TimeZone
    ) throws -> Outcome {
        let fileName = (name as NSString).lastPathComponent
        let built = TranscriptItemText.build(transcript, fileName: fileName, timeZone: timeZone)
        // Every cue was empty once its words were trimmed: nothing to hear.
        guard !built.text.isEmpty else { return .failed(TranscriptImportMessage(.noTimedLines, fileName: fileName)) }
        let item = Item(
            id: built.id, title: built.title, mediaType: "text", text: built.text, externalReference: fileName,
            status: "needs_listening_map", externalReferenceType: TranscriptItemText.referenceType, createdAt: now)
        let saved = try store.saveTranscriptItem(
            item, times: TranscriptTimes(transcript: transcript, built: built), readdedAt: now,
            stillListeningItemIds: stillListeningItemIds)
        return .added(itemId: saved.item.id, title: saved.item.title, readded: saved.readded)
    }
}
