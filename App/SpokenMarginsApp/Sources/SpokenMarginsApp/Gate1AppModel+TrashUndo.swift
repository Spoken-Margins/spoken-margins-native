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
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            if id == Self.guidedOnboardingItemId {
                UserDefaults.standard.set(true, forKey: Self.guidedOnboardingTombstoneKey)
            }
            if let engine, engine.currentSession?.itemId == id {
                snapshot = try endEngineSession(engine, reason: .itemTrashed)
            }
            try store.moveItemToTrash(id: id)
            try refreshLibraryRows(store: store)
            // An import-only item can be selected without a session. Clearing that idle selection must not
            // discard another item's live session just because its detail page was open when Delete was tapped.
            if snapshot.itemId == id { snapshot = SessionSnapshot() }
            if activeItemId == id {
                activeItemId = libraryItems.first?.id ?? "item-pill"
                exportPreview = ""
                selectedItem = libraryItems.first.map { (try? loadItemDetail(id: $0.id, store: store)) ?? ItemDetailState() } ?? ItemDetailState()
            }
            screen = .home
            withdrawFeedback(aboutItem: id)
            presentTrashUndo(itemId: id, title: item.title)
            reportSuccess("Moved \(item.title) to Recently Deleted.")
        } catch {
            reportFailure(error, context: "Move to Recently Deleted failed")
        }
    }

    func undoLastTrash() {
        guard let trashUndo else { return }
        restoreItem(id: trashUndo.itemId)
    }

    func dismissTrashUndo() {
        dismissTrashUndo(id: nil)
    }

    private func presentTrashUndo(itemId: String, title: String) {
        trashUndoDismissTask?.cancel()
        let undo = TrashUndoState(itemId: itemId, title: title)
        trashUndo = undo
        // VoiceOver and Switch Control listeners keep the banner until they act on it (#1926).
        guard !TrashUndoPolicy.staysUntilDismissed(assistiveTechnologyRunning: Self.assistiveTechnologyIsRunning) else {
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

    private static var assistiveTechnologyIsRunning: Bool {
        #if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        false
        #endif
    }

    private func dismissTrashUndo(id: UUID?) {
        guard id == nil || trashUndo?.id == id else { return }
        trashUndoDismissTask?.cancel()
        trashUndoDismissTask = nil
        trashUndo = nil
    }

    func restoreItem(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            try store.restoreItem(id: id)
            try refreshLibraryRows(store: store)
            dismissTrashUndo()
            reportSuccess("Restored \(item.title).")
        } catch {
            reportFailure(error, context: "Restore failed")
        }
    }

    func permanentlyDeleteItem(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            guard item.deletedAt != nil else {
                reportFailure("Move the item to Recently Deleted before deleting it permanently.")
                return
            }
            let recordings = try store.loadInterjections(itemId: id)
            let quarantinedRecordings = try store.quarantinedMarginAudioPaths(itemId: id)
            podcastDownloadCoordinator?.removeItem(id)
            removeDurableGeneratedAudio(for: item)
            removeEpisodeMapArtifacts(itemId: id)
            try store.deleteItem(id: id)
            removeLiveSessionRecord(itemId: id)
            removeMarginRecordings(recordings, quarantinedAudioPaths: quarantinedRecordings, store: store)
            try refreshLibraryRows(store: store)
            guard !libraryItems.contains(where: { $0.id == id }),
                  !recentlyDeletedItems.contains(where: { $0.id == id }),
                  (try? store.loadItem(id: id)) == nil,
                  (try? store.loadSessions(itemId: id))?.isEmpty != false else {
                throw SessionKitError.persistenceFailed("permanent_delete_verification_failed")
            }
            if trashUndo?.itemId == id {
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
            let items = try ids.map { try store.loadItem(id: $0) }
            for item in items {
                guard item.deletedAt != nil else {
                    throw SessionKitError.persistenceFailed("bulk_delete_requires_trashed_items")
                }
            }
            let recordings = try ids.flatMap { try store.loadInterjections(itemId: $0) }
            let quarantinedRecordings = try ids.flatMap { try store.quarantinedMarginAudioPaths(itemId: $0) }
            ids.forEach { podcastDownloadCoordinator?.removeItem($0) }
            items.forEach(removeDurableGeneratedAudio)
            ids.forEach(removeEpisodeMapArtifacts)
            try store.deleteItems(ids: ids)
            ids.forEach(removeLiveSessionRecord)
            removeMarginRecordings(recordings, quarantinedAudioPaths: quarantinedRecordings, store: store)
            try refreshLibraryRows(store: store)
            guard recentlyDeletedItems.isEmpty,
                  ids.allSatisfy({ (try? store.loadItem(id: $0)) == nil }) else {
                throw SessionKitError.persistenceFailed("bulk_permanent_delete_verification_failed")
            }
            if let undoItemId = trashUndo?.itemId, ids.contains(undoItemId) {
                dismissTrashUndo()
            }
            withdrawFeedback(aboutItems: ids)
            reportSuccess("Permanently deleted \(ids.count) item\(ids.count == 1 ? "" : "s") from Recently Deleted.")
        } catch {
            reportFailure(error, context: "Empty Recently Deleted failed")
        }
    }
}
