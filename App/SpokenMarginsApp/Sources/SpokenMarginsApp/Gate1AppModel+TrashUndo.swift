import Foundation
import SessionKit
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif

/// Recently Deleted actions and undo. Moved out of `Gate1AppModel.swift` unchanged (#1007).
extension Gate1AppModel {
    func moveItemToTrash(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("move_item_to_trash") else { return }
        do {
            let title = try trashItemQuietly(id: id, store: try requireStore())
            screen = .home
            presentTrashUndo(TrashUndoState(itemId: id, title: title))
            reportSuccess("Moved \(title) to Recently Deleted.")
        } catch {
            reportFailure(error, context: "Move to Recently Deleted failed")
        }
    }

    /// One item to Recently Deleted with everything that goes with it, and no banner: the row's delete and Select's bulk
    /// delete (#4720) both run this, then each says what it did once. Returns the item's title.
    func trashItemQuietly(id: String, store: SQLiteSessionStore) throws -> String {
        guard let item = try store.loadItemSummary(id: id) else { throw SessionKitError.missingFixture("item:\(id)") } // the title is all it needs (#2506)
        if id == Self.guidedOnboardingItemId {
            UserDefaults.standard.set(true, forKey: Self.guidedOnboardingTombstoneKey)
        }
        if let engine, engine.currentSession?.itemId == id {
            snapshot = try endEngineSession(engine, reason: .itemTrashed)
        }
        try store.moveItemToTrash(id: id)
        removeMarginRows(forItem: id) // its Margins leave the list with it
        showAsRecentlyDeleted(itemId: id, title: item.title)
        // An import-only item can be selected without a session. Clearing that idle selection must not
        // discard another item's live session just because its detail page was open when Delete was tapped.
        if snapshot.itemId == id { snapshot = SessionSnapshot() }
        if activeItemId == id {
            let fallbackId = libraryItems.first?.id
            activeItemId = fallbackId ?? "item-pill"
            exportPreview = ""
            selectedItem = ItemDetailState() // the screen is Home; the replacement's detail arrives from a background read (#2505)
            if let fallbackId { selectFallbackItemInBackground(id: fallbackId, store: store) }
        }
        withdrawFeedback(aboutItem: id)
        return item.title
    }

    /// The detail of the item the listener lands on after deleting the one they had open, read off the main thread. The
    /// delete used to decode that whole item before returning (#2505). It is dropped if the selection moved on meanwhile,
    /// and it offers no follow suggestion: the listener did not choose this item.
    private func selectFallbackItemInBackground(id: String, store: SQLiteSessionStore) {
        let generation = backgroundRefresh.beginItem()
        backgroundRefresh.holdItem(Task { [weak self] in
            guard let self, let detail = try? await self.loadItemDetailOffMain(id: id, store: store) else { return }
            guard !Task.isCancelled, self.backgroundRefresh.isCurrentItem(generation), self.activeItemId == id else { return }
            self.backgroundRefresh.publishItem { if self.selectedItem != detail { self.selectedItem = detail } }
        })
    }

    /// Moves one row from the Library to Recently Deleted on the spot, then lets a background reload confirm it (#2505).
    /// The trash tap used to rebuild every row from SQLite on the main thread; the row's new state is already known.
    private func showAsRecentlyDeleted(itemId: String, title: String) {
        libraryItems.removeAll { $0.id == itemId }
        recentlyDeletedItems.removeAll { $0.id == itemId }
        recentlyDeletedItems.insert(LibraryItemRow(id: itemId, title: title, status: "Recently deleted", canDelete: true), at: 0)
        refreshLibraryRowsInBackground(mustPublish: true)
    }

    /// Undo brings back everything the delete moved: one item, or all of a Select delete (#4720).
    func undoLastTrash() {
        guard let trashUndo else { return }
        if trashUndo.itemIds.count == 1 { restoreItem(id: trashUndo.itemId) } else { restoreItems(trashUndo.batch) }
    }

    func dismissTrashUndo() {
        dismissTrashUndo(id: nil)
    }

    func presentTrashUndo(_ undo: TrashUndoState) {
        trashUndoDismissTask?.cancel()
        trashUndo = undo
        // VoiceOver and Switch Control listeners keep the banner until they act on it (#1926).
        guard !TrashUndoPolicy.staysUntilDismissed(assistiveTechnologyRunning: AssistiveTechnology.isRunning) else {
            trashUndoDismissTask = nil
            return
        }
        trashUndoDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: trashUndoDismissDelay)
                dismissTrashUndo(id: undo.id)
            } catch {
                // Manual dismissal, Undo, replacement, and teardown cancel this timer.
            }
        }
    }

    private func dismissTrashUndo(id: UUID?) {
        guard id == nil || trashUndo?.id == id else { return }
        trashUndoDismissTask?.cancel()
        trashUndoDismissTask = nil
        trashUndo = nil
    }

    /// A permanent delete takes its rows off both lists at once and reads no table: the delete is the one change, and
    /// the row it removes is known. The reload that follows is read off the main thread (it publishes the Preparing
    /// Audio lists too). A row leaving either list bumps `libraryPresentationRevision` (each list's didSet does), so a
    /// read that began before it is read again, Home's read drops its answer, and neither can put the row back (#2505).
    private func dropPermanentlyDeletedRows(ids: Set<String>) {
        if libraryItems.contains(where: { ids.contains($0.id) }) { libraryItems.removeAll { ids.contains($0.id) } }
        if recentlyDeletedItems.contains(where: { ids.contains($0.id) }) { recentlyDeletedItems.removeAll { ids.contains($0.id) } }
        refreshLibraryRowsInBackground(mustPublish: true)
    }

    func restoreItem(id: String) {
        do {
            let title = try restoreItemQuietly(id: id, store: try requireStore())
            refreshLibraryRowsInBackground(mustPublish: true)
            dismissTrashUndo()
            reportSuccess("Restored \(title).")
        } catch {
            reportFailure(error, context: "Restore failed")
        }
    }

    /// One item back from Recently Deleted, with its Margins, and no banner: Restore and a Select delete's Undo both run
    /// it (#4720). Returns the item's title.
    func restoreItemQuietly(id: String, store: SQLiteSessionStore) throws -> String {
        guard let item = try store.loadItemSummary(id: id) else { throw SessionKitError.missingFixture("item:\(id)") }
        try store.restoreItem(id: id)
        refreshMarginRowsInBackground(forItem: id) // and come back with it
        return item.title
    }

    func permanentlyDeleteItem(id: String) {
        do {
            let store = try requireStore()
            guard let item = try store.loadItemSummary(id: id) else { throw SessionKitError.missingFixture("item:\(id)") }
            guard item.deletedAt != nil else {
                reportFailure("Move it to Recently Deleted before deleting it permanently.")
                return
            }
            let recordings = try store.loadInterjections(itemId: id)
            let quarantinedRecordings = try store.quarantinedMarginAudioPaths(itemId: id)
            let ledgerRows = try store.loadOwnedOfflineAssets(itemId: id) // named before any file goes (#4227)
            podcastDownloadCoordinator?.queueRemoval(id)
            removeDurableGeneratedAudio(for: item)
            removeEpisodeMapArtifacts(itemId: id)
            try purgingItemFiles(
                ofItems: [id], ledgerRows: ledgerRows,
                recordingPaths: recordings.compactMap(\.audioPath) + quarantinedRecordings, store: store
            ) {
                try deletingFriendRecordings(ofItems: [id], store: store) { try store.deleteItem(id: id) }
            }
            removeLiveSessionRecord(itemId: id)
            removeFromQueue(deletedItemIds: [id])
            dropPermanentlyDeletedRows(ids: [id])
            guard !libraryItems.contains(where: { $0.id == id }),
                  !recentlyDeletedItems.contains(where: { $0.id == id }),
                  (try? store.loadItemSummary(id: id)) == nil,
                  (try? store.loadSessions(itemId: id))?.isEmpty != false else {
                throw SessionKitError.persistenceFailed("permanent_delete_verification_failed")
            }
            if trashUndo?.batch.contains(id) == true {
                dismissTrashUndo()
            }
            withdrawFeedback(aboutItem: id)
            reportSuccess("Permanently deleted \(item.title).")
        } catch {
            reportFailure(error, context: "Permanent delete failed")
        }
    }

    func permanentlyDeleteRecentlyDeletedItems() {
        do {
            let store = try requireStore()
            let ids = recentlyDeletedItems.map(\.id)
            guard !ids.isEmpty else {
                reportSuccess("Recently Deleted is already empty.")
                return
            }
            let items = try ids.map { id in
                guard let item = try store.loadItemSummary(id: id) else { throw SessionKitError.missingFixture("item:\(id)") }
                return item
            }
            for item in items {
                guard item.deletedAt != nil else {
                    throw SessionKitError.persistenceFailed("bulk_delete_requires_trashed_items")
                }
            }
            let recordings = try ids.flatMap { try store.loadInterjections(itemId: $0) }
            let quarantinedRecordings = try ids.flatMap { try store.quarantinedMarginAudioPaths(itemId: $0) }
            let ledgerRows = try ids.flatMap { try store.loadOwnedOfflineAssets(itemId: $0) } // named before any file goes (#4227)
            ids.forEach { podcastDownloadCoordinator?.queueRemoval($0) }
            items.forEach { removeDurableGeneratedAudio(for: $0) }
            ids.forEach(removeEpisodeMapArtifacts)
            try purgingItemFiles(
                ofItems: ids, ledgerRows: ledgerRows,
                recordingPaths: recordings.compactMap(\.audioPath) + quarantinedRecordings, store: store
            ) {
                try deletingFriendRecordings(ofItems: ids, store: store) { try store.deleteItems(ids: ids) }
            }
            ids.forEach(removeLiveSessionRecord)
            removeFromQueue(deletedItemIds: ids)
            dropPermanentlyDeletedRows(ids: Set(ids))
            guard recentlyDeletedItems.isEmpty,
                  ids.allSatisfy({ (try? store.loadItemSummary(id: $0)) == nil }) else {
                throw SessionKitError.persistenceFailed("bulk_permanent_delete_verification_failed")
            }
            if let undo = trashUndo, ids.contains(where: undo.batch.contains) {
                dismissTrashUndo()
            }
            withdrawFeedback(aboutItems: ids)
            reportSuccess("Permanently deleted \(ids.count) from Recently Deleted.")
        } catch {
            reportFailure(error, context: "Empty Recently Deleted failed")
        }
    }
}
