import Foundation

/// Owns only app-generated files. The journal is committed before the write, so
/// retries after interruption reconcile either the old or intended new bytes.
/// A note the listener edited is left as is and counted, not reported as a failure (#581).
public actor AutomaticMarginWriter {
    /// `fileName` is the name the note was first written under, kept only for notes that ask for a name (#587), so a
    /// journal written by an earlier build decodes as it was and a Margin note's entry stays as it was.
    struct Entry: Codable {
        var previous: String?
        var intended: String
        var fileName: String?
        init(previous: String?, intended: String, fileName: String? = nil) {
            self.previous = previous; self.intended = intended; self.fileName = fileName
        }
    }
    /// `fileName` is the name an item note asks for; nil gives `Margin-<digest of id>.md`.
    public struct Note: Sendable {
        public let id: String
        public let markdown: String
        public var fileName: String?
        public init(id: String, markdown: String, fileName: String? = nil) {
            self.id = id; self.markdown = markdown; self.fileName = fileName
        }
    }
    let journalURL: URL
    public init(journalURL: URL) { self.journalURL = journalURL }

    public func deliver(_ notes: [Note], to folder: URL, destinationID: String) throws -> MarginNoteDelivery.Summary {
        try deliverReportingKeptEdits(notes, to: folder, destinationID: destinationID).summary
    }

    /// `deliver`, plus which notes the listener had edited and were left as they are, so a pass that
    /// covers only some notes can still report the whole folder (#1192).
    public func deliverReportingKeptEdits(
        _ notes: [Note], to folder: URL, destinationID: String
    ) throws -> (summary: MarginNoteDelivery.Summary, keptEditIDs: Set<String>) {
        var keptEditIDs: Set<String> = []
        var journal: [String: Entry] = [:]
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: journalURL))
        }
        var summary = MarginNoteDelivery.Summary()
        let granted = Self.beginAccess(to: folder)
        defer { if granted { Self.endAccess(to: folder) } }
        for note in notes {
            let id = ListeningEdition.digest(note.id)
            let key = destinationID + ":" + id
            let old = journal[key]
            // An item's title can change after its note was written; the first name stays, so the note is rewritten
            // in place and no second copy appears (#587).
            let requestedName = old?.fileName ?? note.fileName
            let file = folder.appendingPathComponent(requestedName ?? "Margin-\(id).md")
            let digest = ListeningEdition.digest(note.markdown)
            var writeError: Error?
            var keptEdit = false
            let coordinationError = Self.coordinateWriting(at: file) { coordinated in
                do {
                    let existing = FileManager.default.fileExists(atPath: coordinated.path)
                        ? try String(contentsOf: coordinated, encoding: .utf8) : nil
                    let actual = existing.map(ListeningEdition.digest)
                    switch MarginNoteDelivery.action(existing: actual, intended: digest, journalPrevious: old?.previous, journalIntended: old?.intended) {
                    case .upToDate:
                        if old == nil {
                            journal[key] = Entry(previous: actual, intended: digest, fileName: requestedName)
                            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                        }
                        return
                    case .keepListenerEdit:
                        keptEdit = true
                        return
                    case .write:
                        break
                    }
                    journal[key] = Entry(previous: actual, intended: digest, fileName: requestedName)
                    try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                    try Data(note.markdown.utf8).write(to: coordinated, options: .atomic)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError as NSError? {
                summary.failures.append(error.localizedDescription)
            } else if keptEdit {
                summary.keptEdits += 1
                keptEditIDs.insert(note.id)
            } else { summary.saved += 1 }
        }
        if let message = MarginNoteDelivery.failureMessage(summary) {
            throw EditionError.invalid(message)
        }
        return (summary, keptEditIDs)
    }

    // The folder is usually in another app's container (a vault in Files), reached through a security-scoped URL and
    // written under file coordination. Both exist only on Apple platforms; elsewhere (the host tests on Linux) the
    // folder is plain and the write goes straight through.
    private static func beginAccess(to folder: URL) -> Bool {
        #if canImport(Darwin)
        folder.startAccessingSecurityScopedResource()
        #else
        false
        #endif
    }

    private static func endAccess(to folder: URL) {
        #if canImport(Darwin)
        folder.stopAccessingSecurityScopedResource()
        #endif
    }

    /// Runs `write` on the file's coordinated URL; returns the coordination error, if it could not be taken.
    private static func coordinateWriting(at file: URL, _ write: (URL) -> Void) -> NSError? {
        #if canImport(Darwin)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError, byAccessor: write)
        return coordinationError
        #else
        write(file)
        return nil
        #endif
    }
}
