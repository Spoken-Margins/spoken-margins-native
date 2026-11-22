import Foundation
import SessionKit

/// What a pick from Files does with the files the transcript rule looks at (#2997).
///
/// A `.vtt`, `.srt`, `.docx` or `.txt` goes through `TranscriptLibraryImport`. Anything the rule does not take (a
/// `.txt` or `.docx` that isn't a transcript, `.md`, `.pdf`, and every other type) comes back in `passthrough`, in the
/// order picked, for today's text import. A Word file there becomes a document item (#4594); one that won't open is
/// passed on too, so the document import refuses it with its own reason (a password, the old `.doc` format). Reading each file, the parse and the store write all run
/// off the caller's actor, one file after another.
///
/// The caller holds the security-scoped access to the picked URLs for the whole call.
public enum TranscriptPickImport {
    public struct Added: Equatable, Sendable {
        public var itemId: String
        public var title: String
        public var readded: Bool
        /// The picked file this transcript came from, so a caller can put its item among the pick's other files.
        public var url: URL
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
            // The cap is checked before the file is read. A `.txt` or `.docx` over it skips the transcript rule and
            // imports as a document, which has its own cap; a `.vtt` or `.srt` over it is refused.
            if let size = fileSize(url), size > TranscriptImport.maximumBytes {
                if fileExtension == "txt" || fileExtension == "docx" { result.passthrough.append(url) }
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
                result.added.append(Added(itemId: itemId, title: title, readded: readded, url: url))
            case .failed(let message):
                // A `.txt` that is not UTF-8 and not a transcript keeps today's import and its words (design, section 2);
                // an empty one, and every other type, is refused with its own sentence.
                if fileExtension == "txt", message.kind == .couldNotRead { result.passthrough.append(url) }
                else if fileExtension == "docx", passesOnWordFailure(message.kind) { result.passthrough.append(url) }
                else { result.refusals.append(message) }
            case .notTranscript:
                // A Word document that isn't a meeting transcript is a document (#4594), as a `.txt` is.
                result.passthrough.append(url)
            }
        }
        return result
    }

    /// The ids of the items a pick saved, in the order the files were picked, for a caller that queues them (the Quick
    /// Folder's swipe-to-queue and inbox, #2997).
    ///
    /// Transcripts come back in `added` and the rest in `passthrough`, each in pick order, and the text import saves
    /// `textItemIds` in `passthrough` order. This walks the pick and takes the next of each as its file comes up. A file
    /// that was refused adds nothing. A text file that failed to save leaves the text ids one short, so the ones after
    /// it shift to earlier files; they keep their order among themselves. The same transcript picked twice is one id.
    public static func itemIdsInPickOrder(
        picked: [URL], added: [Added], passthrough: [URL], textItemIds: [String]
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func take(_ id: String) { if seen.insert(id).inserted { ordered.append(id) } }
        var addedIndex = 0
        var passthroughIndex = 0
        var textIndex = 0
        for url in picked {
            if addedIndex < added.count, added[addedIndex].url == url {
                take(added[addedIndex].itemId)
                addedIndex += 1
            } else if passthroughIndex < passthrough.count, passthrough[passthroughIndex] == url {
                passthroughIndex += 1
                if textIndex < textItemIds.count {
                    take(textItemIds[textIndex])
                    textIndex += 1
                }
            }
        }
        return ordered
    }

    /// A Word file the transcript rule couldn't read, or found empty, goes to the document import, which says why in
    /// the words of a document (#4594). What the rule says of a transcript it read stays its own.
    private static func passesOnWordFailure(_ kind: TranscriptImportMessage.Kind) -> Bool {
        kind == .docxUnreadable || kind == .empty || kind == .tooLarge
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
