import Foundation

/// A spoken note's words on their own, for Export's "Text only" (#3660): what the share sheet hands to Notes, Messages and
/// Copy as real text, and to Files as a `.txt` named after the note. The file is a copy in a folder made for this export;
/// `discard()` removes the folder when the sheet closes.
public struct SpokenNoteTextExport: Equatable, Sendable {
    /// The note's title on one line, for a mail's subject.
    public let title: String
    /// The title, a blank line, then every word of the note in order.
    public let text: String
    public let folderURL: URL
    public let fileURL: URL
    /// Takes with no words written down (silent, or failed), so the text leaves them out.
    public let takesWithoutWordsCount: Int

    public var isPartial: Bool { takesWithoutWordsCount > 0 }

    public func discard() {
        try? FileManager.default.removeItem(at: folderURL)
    }
}

/// Which form of the text a share destination gets (#3660). The sheet is offered both a String and a `.txt`, because a
/// String alone leaves Files without a named file and a file alone is not text to Notes, Messages or Copy.
public enum SpokenNoteTextDelivery: Equatable, Sendable {
    case text, file, textAndFile

    private static let textDestinations: Set<String> = [
        "com.apple.UIKit.activity.CopyToPasteboard",
        "com.apple.UIKit.activity.Message",
        "com.apple.UIKit.activity.Mail",
        "com.apple.UIKit.activity.Print",
        "com.apple.mobilenotes.SharingExtension",
        "com.apple.reminders.sharingextension",
        "com.apple.reminders.RemindersEditorExtension",
    ]
    private static let fileDestinations: Set<String> = [
        "com.apple.DocumentManagerUICore.SaveToFiles",
        "com.apple.CloudDocsUI.AddToiCloudDrive",
        "com.apple.UIKit.activity.AirDrop",
    ]

    /// `activityType` is the destination's raw identifier. One this list doesn't know (a third-party app, or an Apple
    /// identifier that changes in a later iOS) gets both forms, so it can take whichever it understands and never nothing.
    public static func forActivity(_ activityType: String?) -> SpokenNoteTextDelivery {
        guard let activityType else { return .textAndFile }
        if textDestinations.contains(activityType) { return .text }
        if fileDestinations.contains(activityType) { return .file }
        return .textAndFile
    }
}

extension SpokenNoteExport {
    /// The title on one line: runs of whitespace and line breaks become one space and control characters go. A blank title
    /// reads as the default name. Unlike a file name it is never shortened.
    static func titleLine(_ title: String) -> String {
        let kept = String(String.UnicodeScalarView(title.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control ? " " : scalar
        }))
        let line = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? SpokenNoteItem.defaultTitle : line
    }

    /// The note as plain text: the title, a blank line, then `transcriptText`. Nil when the note has no words yet.
    public static func plainText(of note: SpokenNote, title: String) -> String? {
        let words = transcriptText(of: note)
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "\(titleLine(title))\n\n\(words)"
    }

    /// Makes the text to share, with its `.txt` in a new folder under `exportRoot`. Throws `noWordsYet` for a note with no
    /// words, so an empty share never reaches the sheet. Needs no audio on this phone and reads none.
    public static func prepareText(note: SpokenNote, title: String, into exportRoot: URL) throws -> SpokenNoteTextExport {
        guard let text = plainText(of: note, title: title) else { throw SpokenNoteExportError.noWordsYet }
        let fileManager = FileManager.default
        let folder = exportRoot.appendingPathComponent("\(exportFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let file = folder.appendingPathComponent("\(fileBaseName(forTitle: title)).txt")
            try Data(text.utf8).write(to: file, options: .atomic)
            return SpokenNoteTextExport(
                title: titleLine(title), text: text, folderURL: folder, fileURL: file,
                takesWithoutWordsCount: note.takes.filter { !$0.hasTranscript }.count)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }
}
