import Foundation

/// Decides what a file is before anything is imported (#2997): a meeting transcript, an ordinary text file, or
/// something to refuse with a plain sentence. Every entry point (Files, Quick Folder, Open In, share, later
/// email) calls this, so one place decides.
public enum TranscriptFileRouter {
    public enum Route: Equatable, Sendable {
        case transcript(ImportedTranscript)
        /// Not a transcript. The decoded text, so the caller can import it as ordinary text (a `.txt`, as today)
        /// or refuse it with `TranscriptImportMessage.Kind.docxNotATranscript` (a `.docx`).
        case notTranscript(text: String)
        case failed(TranscriptImportMessage)
    }

    /// A text file is a transcript only when all three hold: two or more cues were found, at least half of them
    /// have a speaker, and no more than eight prose lines come before the first cue. An agenda, a recipe or lyrics
    /// with times, or a chat log with names but no times, fail at least one.
    public static let minimumCues = 2
    public static let maximumPreambleLines = 8

    public static func isTranscript(_ transcript: ImportedTranscript) -> Bool {
        let withSpeaker = transcript.cues.filter { $0.speaker != nil }.count
        return transcript.cues.count >= minimumCues
            && transcript.cues.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && withSpeaker * 2 >= transcript.cues.count
            && transcript.skippedHeaderLineCount <= maximumPreambleLines
    }

    /// For text that has already been decoded (the share drain). Nil when it is not a transcript.
    public static func isTranscript(text: String, timeZone: TimeZone = .current) -> ImportedTranscript? {
        guard let transcript = try? TranscriptImport.parse(text: text, timeZone: timeZone), isTranscript(transcript) else { return nil }
        return transcript
    }

    /// `docxText` reads a Word file's text. It is passed in because `DocxPlainText` lives in `SessionKitEPUB`,
    /// which depends on this module.
    public static func route(
        fileName: String,
        data: Data,
        docxText: (Data) throws -> String,
        timeZone: TimeZone = .current
    ) -> Route {
        func failure(_ kind: TranscriptImportMessage.Kind) -> Route { .failed(TranscriptImportMessage(kind, fileName: fileName)) }
        guard !data.isEmpty else { return failure(.empty) }
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        switch fileExtension {
        case "vtt", "srt":
            do {
                let transcript = try TranscriptImport.parse(data: data, timeZone: timeZone)
                guard transcript.cues.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    return failure(.noTimedLines)
                }
                return .transcript(transcript)
            } catch let error as TranscriptImport.Failure {
                return failure(message(for: error))
            } catch {
                return failure(.noTimedLines)
            }
        case "docx":
            guard data.count <= TranscriptImport.maximumBytes else { return failure(.tooLarge) }
            let text: String
            do { text = try docxText(data) } catch { return failure(.docxUnreadable) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failure(.empty) }
            if let transcript = isTranscript(text: text, timeZone: timeZone) { return .transcript(transcript) }
            return .notTranscript(text: text)
        default:
            // A `.txt` (and anything else that reaches here): an ordinary text file unless it reads as a
            // transcript. A file over the cap is never sniffed, so it keeps today's text import. Today's import
            // reads UTF-8 only and fails on anything else, so a file that is not a transcript and not UTF-8 fails
            // the same way here instead of importing as garbage.
            if data.count <= TranscriptImport.maximumBytes {
                do {
                    let transcript = try TranscriptImport.parse(data: data, timeZone: timeZone)
                    if isTranscript(transcript) { return .transcript(transcript) }
                } catch TranscriptImport.Failure.empty {
                    return failure(.empty)
                } catch {}
            }
            guard let text = String(data: data, encoding: .utf8) else { return failure(.couldNotRead) }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return failure(.empty) }
            return .notTranscript(text: text)
        }
    }

    private static func message(for failure: TranscriptImport.Failure) -> TranscriptImportMessage.Kind {
        switch failure {
        case .empty: .empty
        case .noCues: .noTimedLines
        case .tooLarge: .tooLarge
        }
    }
}
