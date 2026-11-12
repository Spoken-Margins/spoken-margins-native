import Foundation

/// What "Export this Margin" does for one Margin (#3211): the owner's rule is that Export means yourself, and
/// that taking a single note out may offer its audio as well.
public enum MarginExportOffer: Equatable, Sendable {
    /// A written Margin, or a voice Margin whose recording is not on this phone: straight to the Markdown note.
    case textOnly
    /// A voice Margin with words and its recording: ask "Text only" or "Audio and text".
    case askTextOrAudio
    /// A voice Margin with its recording but no words yet: straight to the audio.
    case audioOnly
    /// No words and no recording on this phone: there is nothing to export.
    case nothing

    public static func offer(hasNote: Bool, recordingIsOnThisPhone: Bool) -> MarginExportOffer {
        switch (hasNote, recordingIsOnThisPhone) {
        case (true, true): .askTextOrAudio
        case (true, false): .textOnly
        case (false, true): .audioOnly
        case (false, false): .nothing
        }
    }
}

public enum MarginExportError: Error, Equatable {
    /// No Markdown note and the recording could not be copied.
    case nothingToExport
}

/// The files one Margin's Export hands to the share sheet: its recording and its Markdown note, as copies in a
/// folder made for this export, so nothing the share sheet does can reach the Margin's own files.
public struct MarginExportFiles: Equatable, Sendable {
    public let folderURL: URL
    public let markdownURL: URL?
    /// Nil when the recording was not asked for, or could not be copied (`recordingLeftOut`).
    public let audioURL: URL?
    /// The recording was asked for but could not be read, so only the words are exported. The app says so.
    public let recordingLeftOut: Bool

    /// What to hand to the share sheet, audio first.
    public var shareURLs: [URL] { [audioURL, markdownURL].compactMap { $0 } }

    /// Removes the export's folder once the share sheet has closed.
    public func discard() {
        try? FileManager.default.removeItem(at: folderURL)
    }
}

public enum MarginExport {
    /// The file name stem for a Margin's recording when there is no Markdown note to take it from:
    /// `Margin - <item title> - <position>`, as the note is named.
    public static func audioBaseName(itemTitle: String, margin: Interjection) -> String {
        "Margin - \(MarginMarkdownShare.safeName(itemTitle)) - \(MarginMarkdownShare.position(mediaTimeMs: margin.anchor.mediaTimeMs, roughPercent: margin.roughPercent))"
    }

    /// Makes the export in a fresh folder under `exportRoot`. The Markdown note keeps its own name and the recording
    /// is copied beside it as the same name with the recording's extension, so the two sort together in Files. A
    /// recording that is not a plain file, or can't be copied, is left out and reported, never an error while there
    /// are words to export.
    ///
    /// - Throws: `nothingToExport` when neither file can be made; a half-made folder is removed before it leaves.
    public static func prepare(
        markdown: MarginMarkdownFile?, recording: URL?, audioBaseName: String, into exportRoot: URL
    ) throws -> MarginExportFiles {
        guard markdown != nil || recording != nil else { throw MarginExportError.nothingToExport }
        let fileManager = FileManager.default
        let folder = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var markdownURL: URL?
            if let markdown {
                markdownURL = folder.appendingPathComponent(markdown.fileName, isDirectory: false)
                try Data(markdown.markdown.utf8).write(to: markdownURL!, options: .atomic)
            }
            var audioURL: URL?
            if let recording, isRegularFile(recording) {
                let stem = markdown.map { $0.fileName.hasSuffix(".md") ? String($0.fileName.dropLast(3)) : $0.fileName } ?? audioBaseName
                let ext = recording.pathExtension.isEmpty ? "m4a" : recording.pathExtension
                let target = folder.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
                do {
                    try fileManager.copyItem(at: recording, to: target)
                    audioURL = target
                } catch {
                    audioURL = nil
                }
            }
            let leftOut = recording != nil && audioURL == nil
            guard markdownURL != nil || audioURL != nil else { throw MarginExportError.nothingToExport }
            return MarginExportFiles(folderURL: folder, markdownURL: markdownURL, audioURL: audioURL, recordingLeftOut: leftOut)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// `attributesOfItem` does not follow a symbolic link, so only a regular file counts, as for every other reader.
    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }
}
