import Foundation

/// Joins a note's takes, in order, into one audio file (#3660). The system one is `SpokenNoteAudioJoiner` in
/// SessionKitAudio; the export below takes it as a parameter so its file handling is tested without AVFoundation.
public protocol SpokenNoteAudioJoining: Sendable {
    /// Writes `sources` end to end to `destination`, which does not exist yet. Throws when it can't.
    func join(_ sources: [URL], to destination: URL) async throws
}

/// What a spoken note's Export hands to the share sheet (#3660): the audio of every take as one file, and the transcript
/// as text. Both are copies in a folder made for this export, so nothing the share sheet does can reach the note's own
/// files; `discard()` removes the folder when the sheet closes.
public struct SpokenNoteExportFiles: Equatable, Sendable {
    public let folderURL: URL
    /// Nil when none of the note's audio files is on this phone.
    public let audioURL: URL?
    /// Nil when no take has a transcript yet.
    public let transcriptURL: URL?
    /// Takes whose audio file wasn't there, so the audio file is shorter than the note.
    public let missingAudioTakeCount: Int

    /// What to hand to the share sheet, audio first.
    public var shareURLs: [URL] { [audioURL, transcriptURL].compactMap { $0 } }

    public func discard() {
        try? FileManager.default.removeItem(at: folderURL)
    }
}

public enum SpokenNoteExportError: Error, Equatable {
    /// No take has audio on this phone and none has a transcript: there is nothing to export.
    case nothingToExport
}

/// Export for a spoken note (#3660, #3658): the Export door of #3211 ("Export means yourself"), so a listener can get
/// their dictation out of the app by hand. It only reads the note; it never moves, changes or deletes it.
public enum SpokenNoteExport {
    /// The longest file name stem kept, in characters. Long enough to read, short enough for any share target.
    public static let maxBaseNameCharacters = 80

    /// The note's text for a file: each take's sentences with one space between, and a blank line between takes. A take
    /// without a transcript adds nothing. No dictated word is dropped or reflowed beyond that.
    public static func transcriptText(of note: SpokenNote) -> String {
        note.takes
            .map { $0.sentences.map(\.text).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// A file name stem from a title: the title's own words with anything a file name can't hold turned into a space
    /// or dropped (path separators, control characters, a leading dot), spaces collapsed, cut to `maxBaseNameCharacters`.
    /// An empty result (a blank title, only punctuation) falls back to `fallback`. Unicode letters are kept as they are.
    public static func fileBaseName(forTitle title: String, fallback: String = SpokenNoteItem.defaultTitle) -> String {
        func cleaned(_ text: String) -> String {
            let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{7F}").union(.controlCharacters).union(.newlines)
            let scalars = text.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) }
            // A word of only dots ("..") and the dots that start the name would make a hidden or parent-folder name.
            var words = String(scalars).split(whereSeparator: \.isWhitespace).filter { !$0.allSatisfy { $0 == "." } }
            if let first = words.first { words[0] = Substring(first.drop(while: { $0 == "." })) }
            let limited = String(words.joined(separator: " ").prefix(maxBaseNameCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
            return limited.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let name = cleaned(title)
        if !name.isEmpty { return name }
        let fallbackName = cleaned(fallback)
        return fallbackName.isEmpty ? SpokenNoteItem.defaultTitle : fallbackName
    }

    /// Makes the files to share, in a new folder under `exportRoot` (the app's temporary directory). The audio is the
    /// takes joined in order, or the one take's own file copied as it is (no re-encoding of a single take). A take whose
    /// audio file is gone is left out and counted. Throws `nothingToExport` when there is neither audio nor text, and
    /// whatever the joiner or the file system throws; a half-made folder is removed before the error leaves.
    public static func prepare(
        note: SpokenNote,
        title: String,
        noteFolder: URL,
        into exportRoot: URL,
        joiner: SpokenNoteAudioJoining
    ) async throws -> SpokenNoteExportFiles {
        let fileManager = FileManager.default
        let present = note.takes.filter { fileManager.fileExists(atPath: noteFolder.appendingPathComponent($0.audioFileName).path) }
        let text = transcriptText(of: note)
        guard !present.isEmpty || !text.isEmpty else { throw SpokenNoteExportError.nothingToExport }

        let folder = exportRoot.appendingPathComponent("SpokenNoteExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let base = fileBaseName(forTitle: title)
            var audioURL: URL?
            if present.count == 1, let only = present.first {
                let source = noteFolder.appendingPathComponent(only.audioFileName)
                let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
                let target = folder.appendingPathComponent("\(base).\(ext)")
                try fileManager.copyItem(at: source, to: target)
                audioURL = target
            } else if present.count > 1 {
                let target = folder.appendingPathComponent("\(base).m4a")
                try await joiner.join(present.map { noteFolder.appendingPathComponent($0.audioFileName) }, to: target)
                audioURL = target
            }
            var transcriptURL: URL?
            if !text.isEmpty {
                let target = folder.appendingPathComponent("\(base).txt")
                try Data(text.utf8).write(to: target, options: .atomic)
                transcriptURL = target
            }
            return SpokenNoteExportFiles(
                folderURL: folder, audioURL: audioURL, transcriptURL: transcriptURL,
                missingAudioTakeCount: note.takes.count - present.count
            )
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }
}
