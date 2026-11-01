import Foundation
import SessionKit
import SessionKitPersistence

/// The Shortcuts "Add Margin" action given an item that isn't playing (#1073). The Margin is written by
/// `StoredSessionMargin` on the item's saved session, with its own engine, so what is playing is not touched;
/// this only brings the model's lists up to date afterwards.
extension Gate1AppModel {
    /// Returns the title of the item that received the Margin. Throws `StoredSessionMargin.Failure` before
    /// writing anything when the text is empty, the item isn't in the Library, or it has no session yet.
    func addWrittenMarginToStoredItem(id itemId: String, text: String) throws -> String {
        guard let store else { throw StoredSessionMargin.Failure.itemNotFound }
        let saved = try StoredSessionMargin.addWritten(text: text, itemId: itemId, repository: store)
        listeningSignals.writtenMargin(itemId: itemId, text: saved.interjection.displayText ?? text)
        refreshMarginRowsInBackground(forItem: itemId)
        if activeItemId == itemId { refreshSelectedItemInBackground() }
        return saved.itemTitle
    }

    /// The Library items the Add Margin action offers. Read from the database, not `libraryItems`, because a
    /// shortcut can run before the Library screen has loaded its rows.
    /// The reads run off the main thread (#2507): Siri and Shortcuts ask while the listener waits on the picker.
    func shortcutItemChoices(startedOnly: Bool, matching query: String? = nil) async -> [StoredSessionMargin.ItemChoice] {
        guard let store else { return [] }
        return (try? await StoreReader(store).shortcutItemChoices(startedOnly: startedOnly, matching: query)) ?? []
    }
}
