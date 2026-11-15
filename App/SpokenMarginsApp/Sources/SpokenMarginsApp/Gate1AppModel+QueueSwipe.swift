import Foundation
import SessionKit

/// The save-then-queue wishes the app holds (#4044), in memory only: a relaunch loses them and the queue file is untouched.
/// `PlayQueueController` is the same shape. The rules live in SessionKit's `SaveThenQueueWishes`.
@MainActor
enum QueueWishController {
    private(set) static var wishes = SaveThenQueueWishes()

    static func register(_ key: String) { wishes.register(key) }

    static func settle(
        _ key: String, _ outcome: SaveThenQueueWishes.Outcome, itemExists: (String) -> Bool
    ) -> [SaveThenQueueWishes.Release] {
        wishes.settle(key, outcome: outcome, itemExists: itemExists)
    }
}

/// Add to Queue and Remove from Queue on a row's swipe, menu and VoiceOver action (#4044). One name everywhere comes from
/// `QueueRowAction`; this file only wires the taps.
extension Gate1AppModel {
    /// A row whose item is in the Library: Add to Queue puts it last, Remove from Queue takes it out. The state is read
    /// from the queue as it is now, so a stale row still does the right thing.
    func toggleQueue(itemId: String) {
        switch QueueRowAction.action(forItem: itemId, queuedItemIds: PlayQueueState.shared.itemIds) {
        case .add:
            queueAppend(itemId: itemId)
        case .remove:
            removeFromQueue(itemId: itemId)
            reportSuccess(QueueRowAction.remove.banner(title: queuedTitle(itemId)))
        }
    }

    /// A followed episode that is not in the Library yet: save it, then queue it once the import lands. The wish is
    /// registered before the import is asked for, because an import already running for this entry (the listener tapped
    /// Add first) returns early and the wish rides on that one.
    func addEntryToQueue(_ entry: FeedEntry) {
        if entry.state == .imported {
            if let itemId = followingLibraryEpisodes[entry.id]?.itemID { toggleQueue(itemId: itemId) }
            return
        }
        QueueWishController.register(entry.id)
        importFollowedSourceEntry(entry)
    }

    /// The episode a Following show row previews: in the Library it toggles the queue, otherwise it saves and queues.
    func queueNewestEpisode(of row: FollowingShowRow) {
        if row.isNewestInLibrary {
            if let itemId = row.playItemID { toggleQueue(itemId: itemId) }
            return
        }
        guard let id = row.addEntryID, let entry = followingShowEntries.first(where: { $0.id == id }) else { return }
        addEntryToQueue(entry)
    }

    /// A Quick Folder file: save it, then queue it. A folder that is gone, or another import already running, takes the
    /// plain Add path, which says why; no wish is registered then.
    func addQuickFolderFileToQueue(_ file: QuickAccessFile) {
        guard let urls = quickAccess.importURLs(for: file), !Self.isQuickFolderLinkList(file), sourceImportTask == nil else {
            importQuickAccessFile(file)
            return
        }
        QueueWishController.register(file.id)
        // A `.txt` that reads as a meeting transcript is saved as a transcript item and queued like any other (#2997).
        importFilesWithTranscriptRule(urls: [urls.fileURL], route: quickFolderSwipeRoute(for: file, folderURL: urls.folderURL))
    }

    /// How a swiped Quick Folder file is imported: dismissed from the folder's list once saved, and its queue wish
    /// settled with the one item it saved, or none when it saved nothing.
    func quickFolderSwipeRoute(for file: QuickAccessFile, folderURL: URL) -> TranscriptPickRoute {
        TranscriptPickRoute(
            securityScopedURLs: [folderURL],
            refreshQuickFolderWhenFinished: true,
            quickAccessFileToDismiss: file,
            onFinished: { [weak self] outcome in self?.settleQueueWish(key: file.id, itemId: outcome.itemIds.first) })
    }

    /// An import for `key` ended: `itemId` is the item it saved, nil when it saved nothing. A wish for it is released to
    /// the queue in tap order, with the one banner that replaces the import's own.
    func settleQueueWish(key: String, itemId: String?) {
        let outcome: SaveThenQueueWishes.Outcome = itemId.map { .imported(itemId: $0) } ?? .failed
        let present = Set(libraryItems.map(\.id))
        for release in QueueWishController.settle(key, outcome, itemExists: { present.contains($0) }) {
            PlayQueueController.update(self) { $0.append(release.itemId) }
            reportConfirmation(QueueRowAction.savedAndQueuedBanner(title: queuedTitle(release.itemId)))
        }
    }
}
