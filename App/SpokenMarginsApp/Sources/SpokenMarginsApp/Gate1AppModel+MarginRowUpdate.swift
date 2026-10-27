import Foundation
import SessionKit

extension Gate1AppModel {
    /// One Margin changed (starred, noted, its transcript or the Margin itself deleted): fix its row from that
    /// session's saved Margins, not by rebuilding every row from every item, session and Margin (#2505).
    /// Falls back to the full rebuild when the row is new to the list or the Margin can't be read.
    func refreshMarginRow(sessionId: String, interjectionId: String) {
        let index = marginRows.firstIndex { $0.interjection.sessionId == sessionId && $0.interjection.id == interjectionId }
        let saved = store.flatMap { try? $0.loadInterjections(sessionId: sessionId) }?.first { $0.id == interjectionId }
        switch MarginCollection.rowChange(saved: saved, isListed: index != nil) {
        case .update:
            guard let index, let saved else { return refreshMarginRows() }
            let old = marginRows[index]
            noteMarginRowsChanged(forItem: old.interjection.itemId) // A read already running must not undo this.
            marginRows[index] = MarginRow(interjection: saved, itemTitle: old.itemTitle, sessionDate: old.sessionDate, place: old.place)
        case .remove:
            guard let index else { return }
            noteMarginRowsChanged(forItem: marginRows[index].interjection.itemId)
            marginRows.remove(at: index)
        case .unchanged:
            return
        case .rebuild:
            return refreshMarginRows()
        }
        marginOutput.deliverSoon() // The Margin's text or place in the list changed (#171).
    }
}
