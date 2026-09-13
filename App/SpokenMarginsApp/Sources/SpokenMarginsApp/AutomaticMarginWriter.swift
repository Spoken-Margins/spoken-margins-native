import Foundation
import SessionKit

/// Owns only app-generated files. The journal is committed before the write, so
/// retries after interruption reconcile either the old or intended new bytes.
actor AutomaticMarginWriter {
    struct Entry: Codable { var previous: String?; var intended: String }
    struct Note: Sendable { let id: String; let markdown: String }
    let journalURL: URL
    init(journalURL: URL) { self.journalURL = journalURL }

    func deliver(_ notes: [Note], to folder: URL, destinationID: String) throws -> Int {
        var journal: [String: Entry] = [:]
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: journalURL))
        }
        var delivered = 0
        var failures: [String] = []
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
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { coordinated in
                do {
                    let existing = FileManager.default.fileExists(atPath: coordinated.path)
                        ? try String(contentsOf: coordinated, encoding: .utf8) : nil
                    let actual = existing.map(ListeningEdition.digest)
                    if actual == digest {
                        if old == nil {
                            journal[key] = Entry(previous: actual, intended: digest)
                            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                        }
                        return
                    }
                    if let actual, actual != old?.intended && actual != old?.previous {
                        throw EditionError.invalid("An exported note was edited outside Spoken Margins. Your edits are preserved. Choose another output folder to export a new copy.")
                    }
                    journal[key] = Entry(previous: actual, intended: digest)
                    try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                    try Data(note.markdown.utf8).write(to: coordinated, options: .atomic)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError as NSError? {
                failures.append(error.localizedDescription)
            } else { delivered += 1 }
        }
        if let first = failures.first {
            throw EditionError.invalid("\(delivered) Margins delivered; \(failures.count) need attention. " + first)
        }
        return delivered
    }
}
