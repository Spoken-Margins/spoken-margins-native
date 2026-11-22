import Foundation
import SessionKit

/// Imports the transcript files the share extension left in the App Group (#2997, PR 5b), one after another, through
/// `TranscriptLibraryImport.importFile`: the one place that decides what a file is, what it is called and what id it gets.
///
/// The app calls this when it launches, comes forward or retries an import, off the main actor. A file is removed only
/// once it has an answer: added (or already there), or refused with a sentence. A store that can't be written to is not an
/// answer, so that file and the ones after it stay for the next drain. Running it twice imports each file once; a kill
/// between the import and the removal imports it again next time, and the id (from the words) makes that the same item.
public enum TranscriptHandoffDrain {
    public struct Added: Equatable, Sendable {
        public var itemId: String
        public var title: String
        public var readded: Bool
        public var fileName: String
    }

    public struct Report: Sendable {
        /// Transcripts now in the Library, oldest share first. The same words shared twice are one id, listed once.
        public var added: [Added] = []
        /// Files that can't be added, each with its own sentence. Their files are gone.
        public var refusals: [TranscriptImportMessage] = []
        /// Files left for the next drain because the store could not save them.
        public var keptForRetry = 0
        /// What stopped the drain, when the store threw. For Diagnostics only: the listener reads nothing from it.
        public var storeError: (any Error)?

        public var isEmpty: Bool { added.isEmpty && refusals.isEmpty && keptForRetry == 0 }
    }

    public static func run(
        folder: TranscriptHandoffFolder,
        store: SQLiteSessionStore,
        docxText: @escaping @Sendable (Data) throws -> String,
        now: Date = Date(),
        stillListeningItemIds: Set<String> = [],
        timeZone: TimeZone = .current
    ) async -> Report {
        var report = Report()
        folder.sweepOrphans(now: now)
        let entries: [TranscriptHandoffFolder.Entry]
        do { entries = try folder.pending() } catch {
            report.storeError = error
            return report
        }
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let data = try? Data(contentsOf: entry.dataURL) else {
                var isDirectory: ObjCBool = false
                // Gone since the listing: another drain took it, and it has its answer. Silence, not a refusal.
                guard FileManager.default.fileExists(atPath: entry.dataURL.path, isDirectory: &isDirectory) else { continue }
                // A file that is there but can't be read right now (the phone is still locked after a restart, memory is
                // short) waits for the next drain. Only something that can never be read (a folder) is an answer.
                guard isDirectory.boolValue else {
                    report.keptForRetry += 1
                    continue
                }
                folder.delete(entry)
                report.refusals.append(TranscriptImportMessage(.couldNotRead, fileName: entry.fileName))
                continue
            }
            let outcome: TranscriptLibraryImport.Outcome
            do {
                outcome = try await TranscriptLibraryImport.importFile(
                    name: entry.fileName, data: data, store: store, docxText: docxText, now: now,
                    stillListeningItemIds: stillListeningItemIds, timeZone: timeZone)
            } catch {
                report.storeError = error
                report.keptForRetry += entries.count - index
                return report
            }
            folder.delete(entry)
            switch outcome {
            case .added(let itemId, let title, let readded):
                if seen.insert(itemId).inserted {
                    report.added.append(Added(itemId: itemId, title: title, readded: readded, fileName: entry.fileName))
                }
            case .failed(let message):
                report.refusals.append(message)
            case .notTranscript:
                // A `.docx` whose text is not a transcript. A `.vtt` or `.srt` never gets here (it is a transcript or fails).
                let kind: TranscriptImportMessage.Kind = (entry.fileName as NSString).pathExtension.lowercased() == "docx"
                    ? .docxNotATranscript : .unsupportedType
                report.refusals.append(TranscriptImportMessage(kind, fileName: entry.fileName))
            }
        }
        return report
    }
}
