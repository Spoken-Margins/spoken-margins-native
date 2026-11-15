import Foundation

/// Where a file another app opened in Spoken Margins goes (#2997, Open In and AirDrop).
///
/// The app declares "Meeting transcript" as a document type it can open (rank Alternate), listing WebVTT, SubRip, Word
/// and plain text. A plain-text type brings in every kind of text file, so the first thing the app asks is whether the
/// file is one it adds at all. One rule decides, for every file that reaches Open In, so a `.txt` opened from Files, a
/// `.txt` picked in Import from Files and a `.txt` in the Quick Folder are never judged three ways.
public enum OpenedDocumentRoute: Equatable, Sendable {
    /// `.vtt`, `.srt`, `.docx` or `.txt`: the transcript rule looks at it first, and a `.txt` that is not a transcript
    /// is imported as ordinary text, exactly as today.
    case transcriptRule
    /// Markdown: today's text import, which the transcript rule would hand it to anyway.
    case text
    /// Some other plain-text type (`.csv`, `.log`, a source file). Nothing is added, and the
    /// listener reads why.
    case unsupported(TranscriptImportMessage)

    /// The extensions the transcript rule reads. The same four as a pick from Files (`TranscriptPickImport`), so the
    /// two entry points cannot drift apart.
    public static let transcriptExtensions: Set<String> = ["vtt", "srt", "docx", "txt"]
    public static let textExtensions: Set<String> = ["md", "markdown"]

    /// The route for a file, or nil when it is not a plain-text document at all (a packet, a PDF, an audio file, a
    /// JSON collection), which keeps whatever route it had before this rule.
    ///
    /// `isPlainText` is whether the system says the file's type conforms to `public.plain-text`; SessionKit has no
    /// type registry, so the app asks and passes the answer.
    public static func route(forFileNamed fileName: String, isPlainText: Bool) -> OpenedDocumentRoute? {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        if transcriptExtensions.contains(fileExtension) { return .transcriptRule }
        if textExtensions.contains(fileExtension) { return .text }
        guard isPlainText else { return nil }
        return .unsupported(TranscriptImportMessage(.unsupportedType, fileName: fileName))
    }
}
