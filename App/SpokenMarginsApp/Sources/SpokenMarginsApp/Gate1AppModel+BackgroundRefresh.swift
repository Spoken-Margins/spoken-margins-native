import Foundation
import SessionKit
import SessionKitPersistence

/// Which reload of the item screen or the Library is the newest (#2102). A tap used to rebuild both from SQLite on the
/// main thread, so a busy library froze the button that was just pressed. The hot taps (pause, skip, seek, rate,
/// chapters, closing the mini player) now read on a background thread and publish on the main one. A result that
/// was overtaken, by a newer reload or by anything else assigning `selectedItem`, is dropped.
@MainActor
final class BackgroundRefreshGate {
    private var itemGeneration = 0
    private var libraryGeneration = 0
    private var itemTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var isPublishingItem = false

    /// Starts a reload and returns its number; the reload before it can no longer publish.
    func beginItem() -> Int {
        itemGeneration &+= 1
        itemTask?.cancel()
        return itemGeneration
    }

    func beginLibrary() -> Int {
        libraryGeneration &+= 1
        libraryTask?.cancel()
        return libraryGeneration
    }

    func holdItem(_ task: Task<Void, Never>) { itemTask = task }
    func holdLibrary(_ task: Task<Void, Never>) { libraryTask = task }
    func isCurrentItem(_ generation: Int) -> Bool { itemGeneration == generation && !isPublishingItem }
    func isCurrentLibrary(_ generation: Int) -> Bool { libraryGeneration == generation }

    /// Called from `selectedItem`'s didSet: an assignment that isn't one of ours is newer than any load in flight.
    func selectionWasAssigned() {
        guard !isPublishingItem else { return }
        itemGeneration &+= 1
        itemTask?.cancel()
    }

    func publishItem(_ body: () -> Void) {
        isPublishingItem = true
        defer { isPublishingItem = false }
        body()
    }
}

extension Gate1AppModel {
    /// The same reload as `refreshSelectedItem()`, read off the main thread. For taps that don't read the result on the
    /// next line; the screen updates a moment later, and not at all when nothing on it changed.
    func refreshSelectedItemInBackground() {
        guard let store, !activeItemId.isEmpty else { return }
        let id = activeItemId
        let snapshotItemId = snapshot.itemId
        let snapshotSessionId = snapshot.sessionId
        let passes = sharedMarginPlacementPasses
        let generation = backgroundRefresh.beginItem()
        backgroundRefresh.holdItem(Task { [weak self] in
            let detail = await Task.detached(priority: .userInitiated) {
                try? ItemDetailLoader.load(
                    id: id, store: store, snapshotItemId: snapshotItemId,
                    snapshotSessionId: snapshotSessionId, placementPasses: passes)
            }.value
            guard let self, let detail, !Task.isCancelled,
                  self.backgroundRefresh.isCurrentItem(generation), self.activeItemId == id else { return }
            self.backgroundRefresh.publishItem {
                if self.selectedItem != detail { self.selectedItem = detail }
            }
            self.offerFollowSuggestionIfEligible(itemId: id, store: store)
        })
    }

    /// A transport tap (skip, seek, rate) that finishes the item reloads on the spot: the next tap, Play or Resume reads
    /// the finished session off `selectedItem`, and a stale one would resume it instead of offering to restart. Rare,
    /// so the main-thread read is acceptable here. Every other tap reloads in the background.
    func refreshSelectedItemAfterTransport() {
        if snapshot.sourceProgressPercent >= 100 { refreshSelectedItem() } else { refreshSelectedItemInBackground() }
    }

    /// The Library list and the Recently deleted list from one read, published when they changed. A single-row change
    /// (a download or a prewarm tick) landing during the read makes it stale; it is read again, not dropped.
    func refreshLibraryRowsInBackground() {
        guard let store else { return }
        let generation = backgroundRefresh.beginLibrary()
        let read = navigationLibraryRead
        backgroundRefresh.holdLibrary(Task { [weak self] in
            for _ in 0..<3 {
                guard let revision = self?.libraryPresentationRevision,
                      let data = try? await read(store) else { return }
                guard let self, !Task.isCancelled, self.backgroundRefresh.isCurrentLibrary(generation) else { return }
                if self.libraryPresentationRevision != revision { continue }
                self.publishLibrary(data)
                self.refreshAudioPreparationPresentation()
                return
            }
        })
    }

    func publishLibrary(_ data: LibraryReadSnapshot) {
        let rows = LibraryRowBuilder.rows(from: data, context: startupAudioContext)
        if libraryItems != rows { libraryItems = rows }
        let deleted = Self.recentlyDeletedRows(from: data)
        if recentlyDeletedItems != deleted { recentlyDeletedItems = deleted }
    }

    static func recentlyDeletedRows(from data: LibraryReadSnapshot) -> [LibraryItemRow] {
        data.items.filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
            .map { LibraryItemRow(id: $0.id, title: $0.title, status: "Recently deleted", canDelete: true) }
    }

    func refreshSelectedItem() {
        guard let store, !activeItemId.isEmpty else { return }
        if let detail = try? hangTelemetry.labels.scoped("loadItemDetail", { try loadItemDetail(id: activeItemId, store: store) }) {
            selectedItem = detail
            selectedListeningEdition = try? ListeningEditionStore.application().load(itemID: activeItemId)
            offerFollowSuggestionIfEligible(itemId: activeItemId, store: store)
        }
    }

    func loadItemDetail(id: String, store: SQLiteSessionStore) throws -> ItemDetailState {
        try ItemDetailLoader.load(
            id: id, store: store,
            snapshotItemId: snapshot.itemId, snapshotSessionId: snapshot.sessionId,
            placementPasses: sharedMarginPlacementPasses)
    }

    func loadLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: startupAudioContext)
    }

    func refreshLibraryRows(store: SQLiteSessionStore) throws {
        let data = try hangTelemetry.labels.scoped("loadLibraryRows") { try LibraryReadSnapshot.read(store: store) }
        libraryItems = LibraryRowBuilder.rows(from: data, context: startupAudioContext)
        recentlyDeletedItems = Self.recentlyDeletedRows(from: data)
        try refreshAudioPreparationPresentation(store: store)
    }
}
