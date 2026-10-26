import Foundation
import SessionKit
import SessionKitPersistence

/// Which refresh of a scope is newest, so an older read that finishes late can't overwrite a newer one.
@MainActor
private enum MarginRowsTickets {
    private static var next = 0
    private static var latest: [String: Int] = [:]

    static func take(_ scope: String) -> Int {
        next += 1
        latest[scope] = next
        return next
    }

    static func isCurrent(_ ticket: Int, _ scope: String) -> Bool { latest[scope] == ticket }
}

/// The Margins list (`marginRows`, `sharedMarginRows`) is read off the main thread and published here (#2505).
/// A change to one item's Margins swaps in that item's rows (`MarginCollection.replacingItem`) instead of reading
/// every item, session and Margin; only opening the Margins tab and pull to refresh read everything.
extension Gate1AppModel {
    /// A full refresh, not awaited. Callers that need the rows afterwards use `refreshMarginRowsAsync`.
    func refreshMarginRowsInBackground() {
        Task { @MainActor [weak self] in await self?.refreshMarginRowsAsync() }
    }

    /// One item's Margins changed (saved, undone, restored with its item): refresh just those rows.
    /// With no item to name (a snapshot with no session), the whole list is refreshed.
    func refreshMarginRowsInBackground(forItem itemId: String?) {
        guard let itemId else { return refreshMarginRowsInBackground() }
        Task { @MainActor [weak self] in await self?.refreshMarginRowsAsync(forItem: itemId) }
    }

    func refreshMarginRowsAsync() async {
        guard let store else { return diagnostics["marginRefresh"] = "failed:no_store" }
        do {
            let scope = "\(ObjectIdentifier(self)).all"
            let ticket = MarginRowsTickets.take(scope)
            let entries = try await StoreReader(store).read { try MarginRowsReading.all(store: $0) }
            guard MarginRowsTickets.isCurrent(ticket, scope) else { return }
            sharedMarginRows = entries.sharedRows.map(sharedRow)
            marginRows = entries.privateRows.map(privateRow)
            marginOutput.deliverSoon() // A Margin or its transcript may be new (#171).
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func refreshMarginRowsAsync(forItem itemId: String) async {
        guard let store else { return diagnostics["marginRefresh"] = "failed:no_store" }
        do {
            let scope = "\(ObjectIdentifier(self)).item.\(itemId)"
            let ticket = MarginRowsTickets.take(scope)
            let fresh = try await StoreReader(store).read { try MarginRowsReading.item(itemId, store: $0) }
            guard MarginRowsTickets.isCurrent(ticket, scope) else { return }
            applyMarginEntries(fresh, forItem: itemId)
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    /// An item moved to Recently Deleted takes its Margins off the list at once; nothing needs reading.
    func removeMarginRows(forItem itemId: String) {
        applyMarginEntries(MarginCollection.Entries(privateRows: [], sharedRows: []), forItem: itemId)
    }

    private func applyMarginEntries(_ fresh: MarginCollection.Entries, forItem itemId: String) {
        let privateEntries = marginRows.map {
            MarginCollection.PrivateEntry(interjection: $0.interjection, itemTitle: $0.itemTitle, sessionDate: $0.sessionDate, place: $0.place)
        }
        let rows = MarginCollection.replacingItem(itemId, in: privateEntries, with: fresh.privateRows).map(privateRow)
        let oldShared = Dictionary(sharedMarginRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sharedEntries = sharedMarginRows.map {
            MarginCollection.SharedEntry(interjection: $0.interjection, layer: $0.layer, itemTitle: $0.itemTitle)
        }
        let freshIDs = Set(fresh.sharedRows.map(\.id))
        let shared = MarginCollection.replacingItem(itemId, in: sharedEntries, with: fresh.sharedRows).map { entry in
            freshIDs.contains(entry.id) ? sharedRow(entry) : (oldShared[entry.id] ?? sharedRow(entry))
        }
        if rows != marginRows { marginRows = rows }
        if shared != sharedMarginRows { sharedMarginRows = shared }
        marginOutput.deliverSoon() // A Margin or its transcript may be new (#171).
    }

    private func privateRow(_ entry: MarginCollection.PrivateEntry) -> MarginRow {
        MarginRow(interjection: entry.interjection, itemTitle: entry.itemTitle, sessionDate: entry.sessionDate, place: entry.place)
    }

    private func sharedRow(_ entry: MarginCollection.SharedEntry) -> SharedMarginRow {
        SharedMarginRow(interjection: entry.interjection, layer: entry.layer, itemTitle: entry.itemTitle,
                        placement: sharedMarginPlacementPasses.pass(itemId: entry.layer.itemId))
    }
}
