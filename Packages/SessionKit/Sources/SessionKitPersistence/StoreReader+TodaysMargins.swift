import Foundation
import SessionKit

/// The day's Margins for the Today's Margins shortcut (#1991), read off the caller's actor. A shortcut can run from a
/// time-of-day automation before any screen has loaded, so this reads the item summaries (no article text), the
/// sessions and a SQL count of each session's active Margins, and decodes Margins only for sessions that have some.
/// Items in Recently Deleted and their Margins are left out, as they are in the Margins tab. Only the finished entries
/// come back; the reads and the sort run on `StoreReader`'s background task.
/// - `madeAt`: when each Margin saved from a live session was made there (`TodaysMarginsDigest.madeAt(records:)`).
extension StoreReader {
    public func todaysMargins(
        on day: Date, calendar: Calendar = .current, madeAt: [String: Date] = [:]
    ) async throws -> [TodaysMarginsDigest.Entry] {
        try await read(priority: .userInitiated) { store in
            let titles = Dictionary(
                try store.listItemSummaries().filter { $0.deletedAt == nil }.map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first })
            let counts = try store.activeInterjectionCountsBySession()
            var candidates: [(margin: Interjection, itemTitle: String, session: Session?)] = []
            for session in try store.loadSessions() {
                guard let title = titles[session.itemId], counts[session.id, default: 0] > 0 else { continue }
                for margin in try store.loadInterjections(sessionId: session.id) where margin.status == "active" {
                    candidates.append((margin, title, session))
                }
            }
            return TodaysMarginsDigest.entries(from: candidates, on: day, calendar: calendar, madeAt: madeAt)
        }
    }
}
