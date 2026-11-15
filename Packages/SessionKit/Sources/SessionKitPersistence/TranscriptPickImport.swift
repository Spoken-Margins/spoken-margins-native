import Foundation
import SessionKit

/// What a pick from Files does with the files the transcript rule looks at (#2997).
///
/// A `.vtt`, `.srt`, `.docx` or `.txt` goes through `TranscriptLibraryImport`. Anything the rule does not take (a
/// `.txt` that isn't a transcript, `.md`, `.pdf`, and every other type) comes back in `passthrough`, in the order
/// picked, for today's text import, which is unchanged. Reading each file, the parse and the store write all run
/// off the caller's actor, one file after another.
///
/// The caller holds the security-scoped access to the picked URLs for the whole call.
public enum TranscriptPickImport {
    public struct Added: Equatable, Sendable {
        public var itemId: String
        public var title: String
        public var readded: Bool
    }

    public struct Result: Equatable, Sendable {
        /// Transcripts now in the Library, in the order picked.
        public var added: [Added] = []
        /// Files handled as transcripts that could not be added, each with its own sentence.
        public var refusals: [TranscriptImportMessage] = []
        /// Files for today's import, in the order picked.
        public var passthrough: [URL] = []

        /// At least one file was handled as a transcript, so the pick gets the transcript banner.
        public var handledAnyTranscript: Bool { !added.isEmpty || !refusals.isEmpty }
    }

    /// The extensions the rule reads. Anything else is `passthrough` without being opened.
    public static let candidateExtensions: Set<String> = ["vtt", "srt", "docx", "txt"]

    public static func isCandidate(_ url: URL) -> Bool {
        candidateExtensions.contains(url.pathExtension.lowercased())
    }

    /// Throws only what the store throws, so a caller can tell a failed save from a refusal.
    public static func run(
        urls: [URL],
        store: SQLiteSessionStore,
        docxText: @escaping @Sendable (Data) throws -> String,
        now: Date = Date(),
        stillListeningItemIds: Set<String> = [],
        timeZone: TimeZone = .current
    ) async throws -> Result {
        var result = Result()
        for url in urls {
            guard isCandidate(url) else { result.passthrough.append(url); continue }
            let name = url.lastPathComponent
            let fileExtension = url.pathExtension.lowercased()
            // The cap is checked before the file is read. A `.txt` over it skips the transcript rule and imports as
            // today; a `.vtt`, `.srt` or `.docx` over it is refused.
            if let size = fileSize(url), size > TranscriptImport.maximumBytes {
                if fileExtension == "txt" { result.passthrough.append(url) }
                else { result.refusals.append(TranscriptImportMessage(.tooLarge, fileName: name)) }
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                result.refusals.append(TranscriptImportMessage(.couldNotRead, fileName: name))
                continue
            }
            let outcome = try await TranscriptLibraryImport.importFile(
                name: name, data: data, store: store, docxText: docxText, now: now,
                stillListeningItemIds: stillListeningItemIds, timeZone: timeZone)
            switch outcome {
            case .added(let itemId, let title, let readded):
                result.added.append(Added(itemId: itemId, title: title, readded: readded))
            case .failed(let message):
                // A `.txt` that is not UTF-8 and not a transcript keeps today's import and its words (design, section 2);
                // an empty one, and every other type, is refused with its own sentence.
                if fileExtension == "txt", message.kind == .couldNotRead { result.passthrough.append(url) }
                else { result.refusals.append(message) }
            case .notTranscript:
                if fileExtension == "docx" {
                    result.refusals.append(TranscriptImportMessage(.docxNotATranscript, fileName: name))
                } else {
                    result.passthrough.append(url)
                }
            }
        }
        return result
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
