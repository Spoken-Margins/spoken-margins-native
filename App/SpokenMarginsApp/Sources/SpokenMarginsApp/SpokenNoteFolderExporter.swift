import Foundation
import SessionKit
import SessionKitAudio

/// What a finished spoken note is saved to a listener's folder as, made ready off the main thread (#3661).
///
/// The files come from the same `SpokenNoteExport.prepare` the Export button uses (#3660); this only finds the note,
/// runs it into a temporary folder, and says what it left out. It reads the note and never changes it.
struct SpokenNoteFolderExporter {
    struct Prepared: Sendable {
        let files: SpokenNoteExportFiles
        let noteId: String
        /// The takes the files were made from, so a note with a new take is rewritten and an unchanged one is not.
        let audioSignature: String
        /// What the files leave out, in plain words, or empty.
        let leftOut: String

        func discard() { files.discard() }
    }

    static func prepare(noteId: String, title: String, applicationSupport: URL?) async -> Result<Prepared, SpokenNoteFolderOutcome> {
        guard let applicationSupport, let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else {
            return .failure(.notOnThisPhone)
        }
        return await Task.detached(priority: .utility) { () -> Result<Prepared, SpokenNoteFolderOutcome> in
            let root = FileManager.default.temporaryDirectory
            SpokenNoteExport.sweepStaleExports(in: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: store.folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(.notOnThisPhone)
            }
            // Read-only, like Export: a note file that can't be read is reported, never set aside.
            guard let note = store.peek() else { return .failure(.unreadableNote) }
            do {
                let files = try await SpokenNoteExport.prepare(
                    note: note, title: title, noteFolder: store.folderURL, into: root, joiner: SpokenNoteAudioJoiner())
                return .success(Prepared(
                    files: files, noteId: noteId, audioSignature: note.takes.map(\.id).joined(separator: ","),
                    leftOut: await SpokenNoteExportModel.partialMessage(files)))
            } catch SpokenNoteExportError.nothingToExport {
                return .failure(.nothingToExport)
            } catch {
                return .failure(.couldNotPrepare)
            }
        }.value
    }
}
