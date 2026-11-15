import Foundation

/// The one banner a pick from Files leaves when at least one file was handled as a transcript (#2997).
///
/// A pick where no file was handled as a transcript keeps today's words, so the caller does not ask for this. Every
/// result goes in the app's banner, whatever the entry point; the Add sheet has already closed by then.
public enum TranscriptPickBanner {
    public enum Banner: Equatable, Sendable {
        /// One transcript, the only file in the pick: the standard "Added ‹title› to Library." with Play now.
        case addedOne(itemId: String, title: String)
        /// A confirmation sentence with no action.
        case confirmation(String)
        /// A refusal sentence, shown as a failure.
        case failure(String)
    }

    /// The most failed names a banner lists before "and K more".
    public static let maximumNamedFailures = 3

    /// - Parameters:
    ///   - added: transcripts now in the Library, in the order picked. The same item twice counts once.
    ///   - refusals: files handled as transcripts that could not be added, each with its own sentence.
    ///   - documentsImported: files of the pick that today's text import added (Markdown, PDF, a `.txt` that isn't a transcript).
    ///   - documentFailureNames: the names of the files that import could not add.
    ///   - pickedCount: how many files the pick held on this route.
    public static func make(
        added: [(itemId: String, title: String)],
        refusals: [TranscriptImportMessage],
        documentsImported: Int,
        documentFailureNames: [String],
        pickedCount: Int
    ) -> Banner {
        var seen = Set<String>()
        let unique = added.filter { seen.insert($0.itemId).inserted }
        if pickedCount == 1 {
            if let only = unique.first { return .addedOne(itemId: only.itemId, title: only.title) }
            if let refusal = refusals.first { return .failure(refusal.errorDescription ?? "Nothing was added.") }
        }
        let imported = unique.count + documentsImported
        let failedNames = refusals.map(\.displayName) + documentFailureNames.map { TranscriptImportMessage.displayName(for: $0) }
        let opening = imported == 0 ? "No files were added." : "Imported \(imported) file\(imported == 1 ? "" : "s")."
        guard !failedNames.isEmpty else { return .confirmation(opening) }
        let shown = failedNames.prefix(maximumNamedFailures).joined(separator: ", ")
        let rest = failedNames.count - maximumNamedFailures
        let names = rest > 0 ? "\(shown) and \(rest) more" : shown
        let sentence = "\(opening) \(failedNames.count) couldn't be added: \(names)."
        return imported == 0 ? .failure(sentence) : .confirmation(sentence)
    }
}
