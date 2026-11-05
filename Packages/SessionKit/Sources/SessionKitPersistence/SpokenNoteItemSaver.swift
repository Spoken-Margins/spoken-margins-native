import Foundation
import SessionKit

/// The database is a spoken note's Library item writer (#3108). The note's coordinator calls it on its own executor,
/// never the main thread, so the app's main-thread model passes the store along and makes no store call of its own.
extension SQLiteSessionStore: SpokenNoteItemWriting {
    public func write(_ item: Item) throws {
        try saveItem(item)
    }
}
