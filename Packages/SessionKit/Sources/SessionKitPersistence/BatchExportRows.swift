import Foundation
import SessionKit

/// One line of the Export Sessions list: a session, the title of its item, and how many active Margins it has.
public struct BatchSessionExportRow: Identifiable, Sendable {
    public let session: Session
    public let itemTitle: String
    public let interjectionCount: Int

    public var id: String { session.id }

    public init(session: Session, itemTitle: String, interjectionCount: Int) {
        self.session = session
        self.itemTitle = itemTitle
        self.interjectionCount = interjectionCount
    }
}

extension SQLiteSessionStore {
    /// The rows of the Export Sessions list (#2507). Item summaries and a SQL count stand in for decoding every
    /// item's text and every session's Margins (#2506), but the three reads still take tens of milliseconds at
    /// Library size, so the screen runs this through `StoreReader`, off the main actor.
    /// A session whose item is gone has no row.
    public func loadBatchExportRows() throws -> [BatchSessionExportRow] {
        let itemsById = Dictionary(try listItemSummaries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activeCounts = try activeInterjectionCountsBySession()
        return try loadSessions().compactMap { session in
            guard let item = itemsById[session.itemId] else { return nil }
            return BatchSessionExportRow(session: session, itemTitle: item.title,
                                         interjectionCount: activeCounts[session.id] ?? 0)
        }
    }
}
