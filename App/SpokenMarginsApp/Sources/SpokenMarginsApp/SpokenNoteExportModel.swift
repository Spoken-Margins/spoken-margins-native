import Foundation
import SessionKit
import SessionKitAudio

/// What the listener picked at a spoken note's Export door (#3660).
enum SpokenNoteExportKind: Sendable {
    case textOnly, audioAndText
}

/// The note an Export was asked for, held while the listener picks what to export.
struct SpokenNoteExportRequest: Sendable {
    let noteFolder: URL
    let noteId: String
    let title: String
    /// The note as it stands on its own screen; nil from a Library row, which reads it from disk.
    let note: SpokenNote?
}

/// Export for a spoken note (#3660): asks text only or audio and text, makes what was picked off the main thread, and
/// holds it while the share sheet is up. The Library's rows and the note's own screen each own one. The file work is
/// `SpokenNoteExport` in SessionKit; this only runs it and shows what it reports. It only reads the note: a note file it
/// can't read is reported, never set aside or rewritten.
@MainActor
final class SpokenNoteExportModel: ObservableObject {
    @Published private(set) var isPreparing = false
    /// Set while the listener is being asked what to export.
    @Published var choosing: SpokenNoteExportRequest?
    /// Set when the audio and text files are ready: the share sheet shows while this is set, and clears it when it closes.
    @Published var files: SpokenNoteExportFiles? {
        didSet { if files == nil, let old = oldValue { old.discard() } }
    }
    /// The same, for text only.
    @Published var text: SpokenNoteTextExport? {
        didSet { if text == nil, let old = oldValue { old.discard() } }
    }
    /// Files that hold less than the whole note, waiting for the listener to say whether to share them anyway.
    @Published private(set) var partial: SpokenNoteExportFiles?
    /// The same, for text only.
    @Published private(set) var partialText: SpokenNoteTextExport?
    /// Text only was picked for a note with no words yet: the listener is told, and offered its audio instead.
    @Published var noWords: SpokenNoteExportRequest?
    /// A plain line for a failed export, shown in an alert.
    @Published var message: String?
    /// The screen that asked has gone: files that finish now are removed, not offered.
    private var isAbandoned = false

    /// A row's Export: asks what to export from the note with this Library id. `applicationSupport` is where notes live.
    func export(noteId: String, title: String, applicationSupport: URL?) {
        guard let applicationSupport, let store = SpokenNoteStarter.store(noteId: noteId, in: applicationSupport) else {
            message = "This note's recordings aren't on this phone."
            return
        }
        ask(SpokenNoteExportRequest(noteFolder: store.folderURL, noteId: noteId, title: title, note: nil))
    }

    /// The note screen's Export: asks what to export from the note as it is now.
    func export(note: SpokenNote, noteFolder: URL, title: String) {
        ask(SpokenNoteExportRequest(noteFolder: noteFolder, noteId: note.id, title: title, note: note))
    }

    private func ask(_ request: SpokenNoteExportRequest) {
        guard !isPreparing else { return }
        isAbandoned = false
        message = nil
        choosing = request
    }

    /// The listener picked. What comes next waits for the question to close: a sheet or alert raised while it is still
    /// going away is dropped by SwiftUI, and text is ready almost at once.
    func choose(_ kind: SpokenNoteExportKind, for request: SpokenNoteExportRequest) {
        guard !isPreparing else { return }
        choosing = nil
        noWords = nil
        isPreparing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.afterAlertCloses)
            self?.run(kind, for: request)
        }
    }

    /// The listener chose to share a partial export, or not.
    func resolvePartial(share: Bool) {
        if let pending = partial {
            partial = nil
            guard share else { pending.discard(); return }
            present(discarding: pending.discard) { $0.files = pending }
        }
        if let pending = partialText {
            partialText = nil
            guard share else { pending.discard(); return }
            present(discarding: pending.discard) { $0.text = pending }
        }
    }

    /// The screen is closing: nothing started here should be offered later, and what is held goes now.
    func abandon() {
        isAbandoned = true
        choosing = nil
        noWords = nil
        files = nil
        text = nil
        resolvePartial(share: false)
    }

    static let afterAlertCloses = Duration.milliseconds(350)

    /// The share sheet is shown a beat after the question closes.
    private func present(discarding discard: @escaping @Sendable () -> Void, _ show: @escaping @MainActor (SpokenNoteExportModel) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.afterAlertCloses)
            if let self, !self.isAbandoned { show(self) } else { discard() }
        }
    }

    /// What the question about a partial export says, for either kind of export.
    var partialQuestion: String? {
        if let partial { return Self.partialMessage(partial) }
        guard let partialText else { return nil }
        return partialText.takesWithoutWordsCount == 1
            ? "1 take has no words written down yet, so the text leaves it out."
            : "\(partialText.takesWithoutWordsCount) takes have no words written down yet, so the text leaves them out."
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

    private enum Prepared: Sendable {
        case files(SpokenNoteExportFiles)
        case text(SpokenNoteTextExport)
    }

    private func run(_ kind: SpokenNoteExportKind, for request: SpokenNoteExportRequest) {
        guard !isAbandoned else {
            isPreparing = false
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Prepared, Error> in
                let root = FileManager.default.temporaryDirectory
                SpokenNoteExport.sweepStaleExports(in: root)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: request.noteFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return .failure(ModelError.notOnThisPhone)
                }
                // Read-only: `peek` never moves an unreadable note file aside the way opening the note does.
                guard let note = request.note ?? SpokenNoteStore(folderURL: request.noteFolder, noteId: request.noteId).peek() else {
                    return .failure(ModelError.unreadableNote)
                }
                do {
                    switch kind {
                    case .textOnly:
                        return .success(.text(try SpokenNoteExport.prepareText(note: note, title: request.title, into: root)))
                    case .audioAndText:
                        return .success(.files(try await SpokenNoteExport.prepare(
                            note: note, title: request.title, noteFolder: request.noteFolder, into: root, joiner: SpokenNoteAudioJoiner())))
                    }
                } catch {
                    return .failure(error)
                }
            }.value
            isPreparing = false
            switch result {
            case .success(.files(let prepared)):
                if isAbandoned {
                    prepared.discard()
                } else if prepared.isPartial {
                    partial = prepared
                } else {
                    files = prepared
                }
            case .success(.text(let prepared)):
                if isAbandoned {
                    prepared.discard()
                } else if prepared.isPartial {
                    partialText = prepared
                } else {
                    text = prepared
                }
            case .failure(let error):
                guard !isAbandoned else { return }
                if (error as? SpokenNoteExportError) == .noWordsYet {
                    noWords = request
                } else {
                    message = Self.failureMessage(error)
                }
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
