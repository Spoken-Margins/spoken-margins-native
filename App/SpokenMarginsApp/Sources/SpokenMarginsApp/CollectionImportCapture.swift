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
    /// A link list's capture listens only to the link imports it runs itself (`CollectionImportMemberContext`). Anything
    /// else that reports while it is set, a share that drains or a clipped page that lands, keeps its own item and banner
    /// (#4683). A folder import keeps listening to everything, as before.
    private let membersOnly: Bool

    init(membersOnly: Bool = false) {
        self.membersOnly = membersOnly
    }

    private var isListening: Bool { !membersOnly || CollectionImportMemberContext.isActive }

    /// An importer saved this item.
    func recordAdded(_ itemID: String) {
        guard isListening else { return }
        if !added.contains(itemID) { added.append(itemID) }
    }

    /// True when the event is the import's own and is kept here instead of shown.
    func holds(_ event: UserFeedbackEvent) -> Bool {
        guard event.origin == nil, isListening else { return false }
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

/// Set while a link list runs one of its own link imports. A task-local, so it follows the import through its awaits and
/// into the tasks it starts, but not into an unrelated task that happens to run on the main actor in between.
enum CollectionImportMemberContext {
    @TaskLocal static var isActive = false
}
