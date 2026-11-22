import Foundation
import SessionKit

/// Listens in while a folder or link list is imported as a collection (#3769). The importers it calls are the ones a
/// single pick uses, and each of those ends by announcing its item; while a capture is set, the announcement is taken
/// here instead (the new item's ID, and any message), so the listener sees one collection row fill in and one line at
/// the end, never a banner per file.
///
/// Only messages with no item origin are held: a banner about an item's own listen (a summary, a Margin transcription)
/// still shows while an import runs.
@MainActor
final class CollectionImportCapture {
    private var added: [String] = []
    private var held: [UserFeedbackEvent] = []

    /// An importer saved this item.
    func recordAdded(_ itemID: String) {
        if !added.contains(itemID) { added.append(itemID) }
    }

    /// True when the event is the import's own and is kept here instead of shown.
    func holds(_ event: UserFeedbackEvent) -> Bool {
        guard event.origin == nil else { return false }
        held.append(event)
        return true
    }

    /// The items saved since the last call, in the order they were saved, and the first failure or warning message
    /// held since then (the reason a file or link did not go in).
    func take() -> (itemIDs: [String], problem: String?) {
        defer { added.removeAll(); held.removeAll() }
        let problem = held.first(where: { $0.kind == .error })?.message ?? held.first(where: { $0.kind == .warning })?.message
        return (added, problem)
    }
}
