import Foundation

/// The sentence a listener reads when a transcript file can't be added (#2997). Each one names the file and says
/// what to do next. It is a `LocalizedError`, so `ListenerErrorText.message(for:)` shows it unchanged.
public struct TranscriptImportMessage: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// 0 bytes, or only whitespace.
        case empty
        /// A `.vtt`, `.srt` or transcript-shaped file with no timed lines.
        case noTimedLines
        /// Over `TranscriptImport.maximumBytes`.
        case tooLarge
        /// A `.docx` that won't unzip or parse.
        case docxUnreadable
        /// A `.docx` whose text isn't a meeting transcript.
        case docxNotATranscript
        /// Open In, a file in iCloud Drive that can't be read yet.
        case couldNotRead
        /// Open In, a plain-text type that isn't a transcript, text or Markdown.
        case unsupportedType
    }

    public var kind: Kind
    public var fileName: String

    public init(_ kind: Kind, fileName: String) {
        self.kind = kind
        self.fileName = fileName
    }

    /// The name as a listener reads it inside curly quotes: one line, no control characters, at most 60.
    public var displayName: String {
        let cleaned = fileName.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let shown = cleaned.isEmpty ? "this file" : cleaned
        return shown.count > 60 ? String(shown.prefix(59)) + "\u{2026}" : shown
    }

    public var errorDescription: String? {
        let name = "\u{201C}\(displayName)\u{201D}"
        switch kind {
        case .empty:
            return "\(name) is empty, so nothing was added."
        case .noTimedLines:
            return "\(name) has no timed lines, so nothing was added. Check that it's the transcript file from your meeting app."
        case .tooLarge:
            return "\(name) is larger than 10 MB, so nothing was added."
        case .docxUnreadable:
            return "\(name) couldn't be read as a Word document. Save it again as .docx and try again."
        case .docxNotATranscript:
            return "\(name) isn't a meeting transcript. Spoken Margins adds Word files only when they are transcripts. To hear it, copy its text and use Paste Text."
        case .couldNotRead:
            return "\(name) couldn't be read. If it's in iCloud Drive, open it in Files so it downloads, then try again."
        case .unsupportedType:
            return "Spoken Margins can't add \(name). It adds meeting transcripts (.vtt, .srt, .docx, .txt) and text or Markdown files."
        }
    }
}
