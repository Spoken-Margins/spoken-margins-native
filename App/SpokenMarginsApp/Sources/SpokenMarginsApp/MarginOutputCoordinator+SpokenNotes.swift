import Foundation
import SessionKit

/// Which spoken notes were saved to which folders, for the line on a note's row (#3661). Read from the writer's journal.
@MainActor
final class SpokenNoteFolderLedger: ObservableObject {
    @Published private(set) var folders: [String: [String]] = [:]

    /// The folders the note was saved to, by name; empty when it was not.
    func savedFolders(forNoteId noteId: String) -> [String] {
        folders[SpokenNoteFolderJournal.noteKey(noteId)] ?? []
    }

    func reload(journalURL: URL) async {
        folders = await Task.detached(priority: .utility) { SpokenNoteFolderJournal.savedFolders(from: journalURL) }.value
    }
}

/// Marking a spoken note complete saves it to the folders the listener set up in Settings (#3661). It uses the same
/// destinations, folder access and "needs access" handling as the Margin notes, so there is one place a folder is
/// chosen and one way it can be lost.
extension MarginOutputCoordinator {
    /// Where the spoken-note journal lives: beside the Margin notes' one, under its own name.
    func spokenNoteJournalURL() throws -> URL {
        let base = try journalURL()
        return base.deletingLastPathComponent().appendingPathComponent("SpokenNote-" + base.lastPathComponent)
    }

    func loadSpokenNoteLedger() {
        guard let url = try? spokenNoteJournalURL() else { return }
        Task { [spokenNotes] in await spokenNotes.reload(journalURL: url) }
    }

    /// Saves the note's audio and transcript to every delivering destination. A destination that is paused is not one:
    /// choosing a folder starts it paused, and nothing is written until the listener turns it on. Safe to call again:
    /// what is already there is left, not rewritten or copied.
    func saveSpokenNote(noteId: String, title: String, applicationSupport: URL?) async -> SpokenNoteFolderOutcome {
        let targets = destinations.filter(\.isEnabled)
        guard !targets.isEmpty else { return destinations.isEmpty ? .noFolder : .folderPaused }
        let prepared: SpokenNoteFolderExporter.Prepared
        switch await SpokenNoteFolderExporter.prepare(noteId: noteId, title: title, applicationSupport: applicationSupport) {
        case .success(let made): prepared = made
        case .failure(let outcome): return outcome
        }
        defer { prepared.discard() }
        let writer: SpokenNoteFolderWriter
        if let existing = spokenNoteWriter {
            writer = existing
        } else {
            guard let url = try? spokenNoteJournalURL() else { return .journalUnavailable }
            writer = SpokenNoteFolderWriter(journalURL: url)
            spokenNoteWriter = writer
        }
        var deliveries: [SpokenNoteFolderDelivery] = []
        var seenFolders: Set<String> = []
        for destination in targets {
            // Re-read: the listener can pause or remove a destination while an earlier one is writing.
            guard let current = self.destination(destination.id), current.isEnabled else { continue }
            let folder: URL
            do { folder = try resolveFolder(of: current) } catch {
                deliveries.append(.init(folderName: current.name, state: .folderUnavailable))
                continue
            }
            // Two destinations on one folder would each get a copy; one is enough.
            guard seenFolders.insert(folder.standardizedFileURL.path).inserted else { continue }
            do {
                let result = try await writer.deliver(
                    prepared.files, noteId: noteId, to: folder, destinationID: current.id,
                    destinationName: current.name, audioSignature: prepared.audioSignature)
                // A file the listener changed is said so, even when another one was written.
                deliveries.append(.init(folderName: current.name, state: !result.keptEdits.isEmpty ? .keptEdits : (result.written.isEmpty ? .upToDate : .saved)))
            } catch {
                deliveries.append(.init(folderName: current.name, state: .failed(ListenerErrorText.message(for: error))))
            }
        }
        if let url = try? spokenNoteJournalURL() { await spokenNotes.reload(journalURL: url) }
        // Every destination was paused or removed while the files were made.
        guard !deliveries.isEmpty else { return .folderPaused }
        return .delivered(deliveries, leftOut: prepared.leftOut)
    }
}
