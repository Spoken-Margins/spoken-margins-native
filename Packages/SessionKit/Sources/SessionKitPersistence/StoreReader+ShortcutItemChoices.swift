import Foundation
import SessionKit

/// The Library items the Add Margin shortcut offers, read off the caller's actor (#2507). A shortcut can run before the
/// Library screen has loaded, so this reads the item summaries and every session from the database; both reads, and the
/// sort over them, run on `StoreReader`'s background task and only the finished choices come back.
extension StoreReader {
    public func shortcutItemChoices(
        startedOnly: Bool,
        matching query: String? = nil
    ) async throws -> [StoredSessionMargin.ItemChoice] {
        try await read(priority: .userInitiated) { store in
            StoredSessionMargin.itemChoices(
                items: try store.listItemSummaries(), sessions: try store.loadSessions(),
                startedOnly: startedOnly, matching: query)
        }
    }
}
