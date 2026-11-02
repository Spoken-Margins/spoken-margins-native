import Foundation
import SessionKit

/// A live session's saves, for a caller off the main actor (#2509, fix class `write-behind`). Saving a session
/// writes the text item (when there is no recording), the session that holds its Margins and one written or spoken
/// Margin each, a few dozen rows for a long meeting. The app runs this through `StoreReader.read` and publishes the
/// screen afterwards, so nothing on the main thread waits for the writes. They go through
/// `StoreReader.readInOrder(orderKey)`, which still runs when the screen that asked is dismissed (a saved session is
/// not dropped half way) and puts two saves in the order they were asked.
public enum LiveSessionWrites {
    public static let orderKey = "live-session-save"

    /// The session's Margins, each paired with the live Margin it came from (`LiveSessionRecord` keeps the pairs).
    public typealias Linked = [(liveId: String, saved: Interjection)]

    /// Saves `item`, the text item a session without a recording becomes, and places the session's Margins on it. The
    /// item is saved first and stays if placing fails, as it did when this ran on the main thread.
    public static func saveTextItem(
        _ item: Item,
        placed: [LiveSessionAlignment.Placed],
        in store: SQLiteSessionStore
    ) throws -> Linked {
        try store.seed(item: item)
        return try LiveSessionMarginPlacer.placeLinked(placed, itemId: item.id, repository: store)
    }
}
