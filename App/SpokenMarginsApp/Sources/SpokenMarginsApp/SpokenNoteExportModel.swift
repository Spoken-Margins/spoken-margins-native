import Foundation
import SessionKit
import SessionKitAudio

/// Export for a spoken note (#3660): makes the audio and transcript files off the main thread and holds them while the
/// share sheet is up. The Library's rows and the note's own screen each own one. The file work is `SpokenNoteExport`
/// in SessionKit; this only runs it and shows what it reports.
@MainActor
final class SpokenNoteExportModel: ObservableObject {
    @Published private(set) var isPreparing = false
    /// Set when the files are ready: the share sheet shows while this is set, and clears it when it closes.
    @Published var files: SpokenNoteExportFiles? {
        didSet { if files == nil, let old = oldValue { old.discard() } }
    }
    /// A plain line for a failed export, shown in an alert.
    @Published var message: String?

    /// Exports a note by its Library id (a row's Export). `applicationSupport` is where notes live.
    func export(noteId: String, title: String, applicationSupport: URL?) {
        guard let applicationSupport, let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else {
            message = "This note's recordings aren't on this phone."
            return
        }
        start(noteFolder: store.folderURL, noteId: noteId, title: title, note: nil)
    }

    /// Exports the note open on its own screen, as it is now.
    func export(note: SpokenNote, noteFolder: URL, title: String) {
        start(noteFolder: noteFolder, noteId: note.id, title: title, note: note)
    }

    private func start(noteFolder: URL, noteId: String, title: String, note: SpokenNote?) {
        guard !isPreparing else { return }
        isPreparing = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SpokenNoteExportFiles, Error> in
                do {
                    let note = note ?? SpokenNoteStore(folderURL: noteFolder, noteId: noteId).load()
                    return .success(try await SpokenNoteExport.prepare(
                        note: note, title: title, noteFolder: noteFolder,
                        into: FileManager.default.temporaryDirectory, joiner: SpokenNoteAudioJoiner()))
                } catch {
                    return .failure(error)
                }
            }.value
            isPreparing = false
            switch result {
            case .success(let prepared):
                files = prepared
            case .failure(let error):
                message = (error as? SpokenNoteExportError) == .nothingToExport
                    ? "This note has no audio or words to export yet."
                    : "Couldn't make the files to export. Nothing was changed in your note."
            }
        }
    }
}
