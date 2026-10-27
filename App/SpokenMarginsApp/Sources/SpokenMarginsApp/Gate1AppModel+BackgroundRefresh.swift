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
    private var mustPublishPending = false
    private var announcePending = false
    private var isPublishingItem = false

    /// Starts a reload and returns its number; the reload before it can no longer publish.
    func beginItem() -> Int {
        itemGeneration &+= 1
        itemTask?.cancel()
        return itemGeneration
    }

    /// A reload that a tap asked to publish (`mustPublish`) and that a newer reload overtook before publishing hands
    /// the obligation on: the newer one must publish too, or the tap's change would never show.
    func beginLibraryReload(mustPublish: Bool) -> (generation: Int, mustPublish: Bool) {
        libraryGeneration &+= 1
        libraryTask?.cancel()
        mustPublishPending = mustPublishPending || mustPublish
        return (libraryGeneration, mustPublishPending)
    }

    func beginLibrary() -> Int { beginLibraryReload(mustPublish: false).generation }

    func libraryWasPublished() { mustPublishPending = false }

    /// The foreground return wants "your audio is ready" announced from whichever Library reload publishes next, so a
    /// reload that overtakes the one that was asked hands the announcement on, like `mustPublish`.
    func requestAnnouncement() { announcePending = true }

    /// True once per request, for the reload that just published.
    func takeAnnouncement() -> Bool {
        defer { announcePending = false }
        return announcePending
    }

    /// Returns once the newest Library reload has published or been dropped, following reloads that overtake it.
    /// For tests that tap, then read the rows.
    func settledLibrary() async {
        while true {
            let generation = libraryGeneration
            await libraryTask?.value
            if generation == libraryGeneration { return }
        }
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

    /// Waits for the Library reload a tap started in the background. Production code never waits; tests do.
    func settleLibraryReload() async { await backgroundRefresh.settledLibrary() }

    /// A transport tap (skip, seek, rate) that finishes the item reloads on the spot: the next tap, Play or Resume reads
    /// the finished session off `selectedItem`, and a stale one would resume it instead of offering to restart. Rare,
    /// so the main-thread read is acceptable here. Every other tap reloads in the background.
    func refreshSelectedItemAfterTransport() {
        if snapshot.sourceProgressPercent >= 100 { refreshSelectedItem() } else { refreshSelectedItemInBackground() }
    }

    /// The Library list and the Recently deleted list from one read, published when they changed. A single-row change
    /// (a download or a prewarm tick) landing during the read makes it stale; it is read again, not dropped.
    ///
    /// `mustPublish` is for a tap that changed the database and expects the screen to show it (Mark complete, Undo,
    /// Restore). Playback ticks and prewarm progress can invalidate every read of a busy Library, and dropping the
    /// reload then would leave the row stale until something else reloads. A `mustPublish` reload reads again like any
    /// other (a synchronous reload that landed meanwhile, such as a permanent delete or the foreground return, is newer than this read
    /// and must not be undone by it), but its third read publishes the rows whatever moved meanwhile (the database is
    /// the truth; the next tick refreshes a moving row), and leaves the Preparing Audio lists alone when their writer
    /// changed them during that read.
    func refreshLibraryRowsInBackground(mustPublish: Bool = false) {
        guard let store else { return }
        let (generation, publishRequired) = backgroundRefresh.beginLibraryReload(mustPublish: mustPublish)
        let read = navigationLibraryRead
        backgroundRefresh.holdLibrary(Task { [weak self] in
            for attempt in 0..<3 {
                guard let revision = self?.libraryPresentationRevision,
                      let listsBefore = self?.audioPreparationLists,
                      let data = try? await read(store) else { return }
                guard let self, !Task.isCancelled, self.backgroundRefresh.isCurrentLibrary(generation) else { return }
                // Moving or prioritizing a job and a chunk's progress set the Preparing Audio lists without touching
                // `libraryItems`, so the revision can't see them: a list that changed during the read is read again.
                let rowsMoved = self.libraryPresentationRevision != revision
                let listsMoved = self.audioPreparationLists != listsBefore
                if (rowsMoved || listsMoved) && !(publishRequired && attempt == 2) { continue }
                self.publishLibrary(data)
                self.backgroundRefresh.libraryWasPublished()
                if !listsMoved { self.publishAudioPreparationPresentation(from: data, store: store) }
                if self.backgroundRefresh.takeAnnouncement() { self.announcePreparedAudioIfNeeded() }
                return
            }
        })
    }

    /// The Preparing Audio lists from the Library read just published, so the reload costs the main thread no second
    /// pass over the store (#2505). Stale jobs are checked again and deleted off it; they are already left out of the queue.
    func publishAudioPreparationPresentation(from data: LibraryReadSnapshot, store: SQLiteSessionStore) {
        let presentation = AudioPreparationPresentation(snapshot: data, activeItemId: activePlaybackItemId)
        if audioPreparationQueue != presentation.queue { audioPreparationQueue = presentation.queue }
        if recentlyPreparedAudio != presentation.recentlyPrepared { recentlyPreparedAudio = presentation.recentlyPrepared }
        let stale = presentation.staleJobIds
        guard !stale.isEmpty else { return }
        Task.detached(priority: .utility) { _ = try? store.deleteStaleAudioPreparationJobs(among: stale) }
    }

    var audioPreparationLists: (queue: [AudioPreparationQueueRow], recentlyPrepared: [RecentlyPreparedAudioRow]) {
        (audioPreparationQueue, recentlyPreparedAudio)
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
