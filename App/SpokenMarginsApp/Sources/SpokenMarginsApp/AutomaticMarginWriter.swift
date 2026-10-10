import Foundation
import SessionKit

/// Owns only app-generated files. The journal is committed before the write, so
/// retries after interruption reconcile either the old or intended new bytes.
/// A note the listener edited is left as is and counted, not reported as a failure (#581).
actor AutomaticMarginWriter {
    struct Entry: Codable { var previous: String?; var intended: String }
    struct Note: Sendable { let id: String; let markdown: String }
    let journalURL: URL
    init(journalURL: URL) { self.journalURL = journalURL }

    func deliver(_ notes: [Note], to folder: URL, destinationID: String) throws -> MarginNoteDelivery.Summary {
        try deliverReportingKeptEdits(notes, to: folder, destinationID: destinationID).summary
    }

    /// `deliver`, plus which notes the listener had edited and were left as they are, so a pass that
    /// covers only some notes can still report the whole folder (#1192).
    func deliverReportingKeptEdits(
        _ notes: [Note], to folder: URL, destinationID: String
    ) throws -> (summary: MarginNoteDelivery.Summary, keptEditIDs: Set<String>) {
        var keptEditIDs: Set<String> = []
        var journal: [String: Entry] = [:]
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: journalURL))
        }
        var summary = MarginNoteDelivery.Summary()
        let granted = folder.startAccessingSecurityScopedResource()
        defer { if granted { folder.stopAccessingSecurityScopedResource() } }
        for note in notes {
            let id = ListeningEdition.digest(note.id)
            let key = destinationID + ":" + id
            let file = folder.appendingPathComponent("Margin-\(id).md")
            let digest = ListeningEdition.digest(note.markdown)
            let old = journal[key]
            var coordinationError: NSError?
            var writeError: Error?
            var keptEdit = false
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { coordinated in
                do {
                    let existing = FileManager.default.fileExists(atPath: coordinated.path)
                        ? try String(contentsOf: coordinated, encoding: .utf8) : nil
                    let actual = existing.map(ListeningEdition.digest)
                    switch MarginNoteDelivery.action(existing: actual, intended: digest, journalPrevious: old?.previous, journalIntended: old?.intended) {
                    case .upToDate:
                        if old == nil {
                            journal[key] = Entry(previous: actual, intended: digest)
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
                    journal[key] = Entry(previous: actual, intended: digest)
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
}
