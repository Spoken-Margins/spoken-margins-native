import Foundation
import SessionKit
import SessionKitAudio

/// Export for a spoken note (#3660): makes the audio and transcript files off the main thread and holds them while the
/// share sheet is up. The Library's rows and the note's own screen each own one. The file work is `SpokenNoteExport`
/// in SessionKit; this only runs it and shows what it reports. It only reads the note: a note file it can't read is
/// reported, never set aside or rewritten.
@MainActor
final class SpokenNoteExportModel: ObservableObject {
    @Published private(set) var isPreparing = false
    /// Set when the files are ready: the share sheet shows while this is set, and clears it when it closes.
    @Published var files: SpokenNoteExportFiles? {
        didSet { if files == nil, let old = oldValue { old.discard() } }
    }
    /// Files that hold less than the whole note, waiting for the listener to say whether to share them anyway.
    @Published private(set) var partial: SpokenNoteExportFiles?
    /// A plain line for a failed export, shown in an alert.
    @Published var message: String?
    /// The screen that asked has gone: files that finish now are removed, not offered.
    private var isAbandoned = false

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

    /// The listener chose to share a partial export, or not.
    func resolvePartial(share: Bool) {
        guard let pending = partial else { return }
        partial = nil
        guard share else {
            pending.discard()
            return
        }
        // The share sheet is shown a beat after the question closes: a sheet raised while an alert is still going away
        // is dropped by SwiftUI.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if let self, !self.isAbandoned { self.files = pending } else { pending.discard() }
        }
    }

    /// The screen is closing: nothing started here should be offered later, and what is held goes now.
    func abandon() {
        isAbandoned = true
        files = nil
        resolvePartial(share: false)
    }

    /// The plain words for what a partial export leaves out.
    static func partialMessage(_ files: SpokenNoteExportFiles) -> String {
        var lines: [String] = []
        if files.missingAudioTakeCount > 0 {
            lines.append(files.missingAudioTakeCount == 1
                ? "The audio of 1 take isn't on this phone or can't be read, so the audio file leaves it out."
                : "The audio of \(files.missingAudioTakeCount) takes isn't on this phone or can't be read, so the audio file leaves them out.")
        }
        if files.takesWithoutTranscriptCount > 0 {
            lines.append(files.takesWithoutTranscriptCount == 1
                ? "1 take has no words written down yet, so the text file leaves it out."
                : "\(files.takesWithoutTranscriptCount) takes have no words written down yet, so the text file leaves them out.")
        }
        return lines.joined(separator: " ")
    }

    private func start(noteFolder: URL, noteId: String, title: String, note: SpokenNote?) {
        guard !isPreparing else { return }
        isPreparing = true
        isAbandoned = false
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SpokenNoteExportFiles, Error> in
                let root = FileManager.default.temporaryDirectory
                SpokenNoteExport.sweepStaleExports(in: root)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: noteFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return .failure(ModelError.notOnThisPhone)
                }
                // Read-only: `peek` never moves an unreadable note file aside the way opening the note does.
                guard let note = note ?? SpokenNoteStore(folderURL: noteFolder, noteId: noteId).peek() else {
                    return .failure(ModelError.unreadableNote)
                }
                do {
                    return .success(try await SpokenNoteExport.prepare(
                        note: note, title: title, noteFolder: noteFolder, into: root, joiner: SpokenNoteAudioJoiner()))
                } catch {
                    return .failure(error)
                }
            }.value
            isPreparing = false
            switch result {
            case .success(let prepared):
                if isAbandoned {
                    prepared.discard()
                } else if prepared.isPartial {
                    partial = prepared
                } else {
                    files = prepared
                }
            case .failure(let error):
                message = Self.failureMessage(error)
            }
        }
    }

    private enum ModelError: Error {
        case notOnThisPhone, unreadableNote
    }

    private static func failureMessage(_ error: Error) -> String {
        switch error {
        case ModelError.notOnThisPhone:
            return "This note's recordings aren't on this phone."
        case ModelError.unreadableNote:
            return "This note can't be read right now, so it can't be exported. Nothing was changed."
        case SpokenNoteExportError.nothingToExport:
            return "This note has no audio or words to export yet."
        default:
            return "Couldn't make the files to export. Nothing was changed in your note."
        }
    }
}
