import Foundation
import SessionKit
import SessionKitPersistence

/// One `MarginRowsSequence` per model: every writer of the Margins list takes its number, so a read that ran off the
/// main thread never publishes over a newer change (#2505; audit on #2747).
@MainActor
enum MarginRowsTickets {
    private static var sequences: [ObjectIdentifier: MarginRowsSequence] = [:]

    static func with<T>(_ model: AnyObject, _ body: (inout MarginRowsSequence) -> T) -> T {
        body(&sequences[ObjectIdentifier(model), default: MarginRowsSequence()])
    }

    /// Test seam: runs after a full read lands and before it is judged, so a test can make a change in between.
    static var fullReadLanded: (@MainActor () async -> Void)?

    /// Background refreshes still running, so a test can wait for them instead of sleeping.
    private static var pending: [Int: Task<Void, Never>] = [:]
    private static var nextTask = 0

    static func track(_ work: @escaping @MainActor () async -> Void) {
        nextTask += 1
        let id = nextTask
        pending[id] = Task { @MainActor in
            await work()
            pending[id] = nil
        }
    }

    static func settle() async {
        while let task = pending.values.first { await task.value }
    }

    /// Dropped reads waiting for the newer read that superseded them to finish (#2766).
    private static var waiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    /// The caller is done with `read`: published, dropped or failed. Wakes the reads waiting on a newer one.
    static func end(_ model: AnyObject, _ read: MarginRowsSequence.Read) {
        with(model) { $0.end(read) }
        for waiter in waiters.removeValue(forKey: ObjectIdentifier(model)) ?? [] { waiter.resume() }
    }

    /// A dropped read's caller returns only once the newer read of its scope has published, so an awaited refresh
    /// never comes back having published nothing.
    static func waitForNewerRead(_ model: AnyObject, _ read: MarginRowsSequence.Read) async {
        while with(model, { $0.isWaitingOnNewerRead(read) }) {
            await withCheckedContinuation { waiters[ObjectIdentifier(model), default: []].append($0) }
        }
    }
}

/// The Margins list (`marginRows`, `sharedMarginRows`) is read off the main thread and published here (#2505).
/// A change to one item's Margins swaps in that item's rows (`MarginCollection.replacingItem`) instead of reading
/// every item, session and Margin; only opening the Margins tab and pull to refresh read everything.
///
/// Its writers: the full read (`refreshMarginRowsAsync()`), the one-item read (`refreshMarginRowsAsync(forItem:)`),
/// the main-thread rebuild (`refreshMarginRows()`), and main-thread changes to rows (`removeMarginRows`,
/// `refreshMarginRow`, `markSharedMarginHeard`), which call `noteMarginRowsChanged`. Each one goes through
/// `MarginRowsTickets`, so a read that began before a newer change reads again instead of undoing it.
extension Gate1AppModel {
    /// A full refresh, not awaited. Callers that need the rows afterwards use `refreshMarginRowsAsync`.
    func refreshMarginRowsInBackground() {
        MarginRowsTickets.track { [weak self] in await self?.refreshMarginRowsAsync() }
    }

    /// One item's Margins changed (saved, undone, restored with its item): refresh just those rows.
    /// With no item to name (a snapshot with no session), the whole list is refreshed.
    func refreshMarginRowsInBackground(forItem itemId: String?) {
        guard let itemId else { return refreshMarginRowsInBackground() }
        MarginRowsTickets.track { [weak self] in await self?.refreshMarginRowsAsync(forItem: itemId) }
    }

    /// Test seam: returns once every background Margins refresh started so far has published.
    func settleMarginRows() async { await MarginRowsTickets.settle() }

    /// Every item's rows, read on the main thread: launch, and a deep link that must find its Margin at once.
    func refreshMarginRows() {
        do {
            // Library rows refresh asynchronously on navigation. Retrieval must
            // use durable membership so freshly imported items are not omitted.
            let entries = try MarginRowsReading.all(store: requireStore())
            MarginRowsTickets.with(self) { $0.noteRebuild() }
            publishMarginEntries(entries)
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func refreshMarginRowsAsync() async {
        guard let store else { return diagnostics["marginRefresh"] = "failed:no_store" }
        var last: MarginRowsSequence.Read?
        defer { if let last { MarginRowsTickets.end(self, last) } }
        do {
            while true {
                let read = MarginRowsTickets.with(self) { $0.beginRead(.all) }
                last = read
                let entries = try await StoreReader(store).read { try MarginRowsReading.all(store: $0) }
                if let landed = MarginRowsTickets.fullReadLanded { await landed() }
                switch MarginRowsTickets.with(self, { $0.finish(read) }) {
                case .publish: return publishMarginEntries(entries)
                case .drop: return await MarginRowsTickets.waitForNewerRead(self, read)
                case .rerun: continue // A Margin changed while this read ran; its rows would undo that change.
                }
            }
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func refreshMarginRowsAsync(forItem itemId: String) async {
        guard let store else { return diagnostics["marginRefresh"] = "failed:no_store" }
        var last: MarginRowsSequence.Read?
        defer { if let last { MarginRowsTickets.end(self, last) } }
        do {
            while true {
                let read = MarginRowsTickets.with(self) { $0.beginRead(.item(itemId)) }
                last = read
                let fresh = try await StoreReader(store).read { try MarginRowsReading.item(itemId, store: $0) }
                switch MarginRowsTickets.with(self, { $0.finish(read) }) {
                case .publish: return applyMarginEntries(fresh, forItem: itemId)
                case .drop: return await MarginRowsTickets.waitForNewerRead(self, read)
                case .rerun: continue
                }
            }
        } catch {
            diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    /// Rows changed on the main thread (starred, noted, heard, removed); a read already running reads again.
    /// With no item to name, every read in flight reads again.
    func noteMarginRowsChanged(forItem itemId: String?) {
        MarginRowsTickets.with(self) { $0.noteChange(itemId.map { .item($0) } ?? .all) }
    }

    /// An item moved to Recently Deleted takes its Margins off the list at once; nothing needs reading.
    func removeMarginRows(forItem itemId: String) {
        noteMarginRowsChanged(forItem: itemId)
        applyMarginEntries(MarginCollection.Entries(privateRows: [], sharedRows: []), forItem: itemId)
    }

    private func publishMarginEntries(_ entries: MarginCollection.Entries) {
        sharedMarginRows = entries.sharedRows.map(sharedRow)
        marginRows = entries.privateRows.map(privateRow)
        marginOutput.deliverSoon() // A Margin or its transcript may be new (#171).
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
