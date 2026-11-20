import Foundation
import SessionKit
import SessionKitPersistence

/// Select's actions on the ticked rows (#4720). Each runs the single-row path once per item, quietly, then says what it
/// did once with the count from `LibraryBulkAction`, so the banner can't disagree with what changed.
extension Gate1AppModel {
    /// Add to Queue: the items go last, in the order given; ones already queued keep their place. Returns how many joined.
    @discardableResult
    func addItemsToQueue(_ itemIds: [String]) -> Int {
        var added = 0
        PlayQueueController.update(self) { added = $0.append(contentsOf: itemIds) }
        reportConfirmation(LibraryBulkAction.queuedBanner(added: added, selected: Set(itemIds).count))
        return added
    }

    /// Mark as Finished: each unfinished item, as its row's Mark Complete does, with one banner whose Undo un-finishes
    /// exactly the items this changed, so items that were already finished stay finished (#4720).
    /// Each item is read whole and saved, so a Select All over a big Library runs off the main thread (#2257); the
    /// signals, note export and banner follow on the main actor once every item is saved.
    func markItemsFinished(_ itemIds: [String]) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_items_completed") else { return }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Mark complete failed"); return }
        Task { @MainActor [weak self] in
            let result = await Self.markCompletion(itemIds) { try ManualItemCompletion.markComplete(itemId: $0, in: store) }
            guard let self else { return }
            for item in result.changed {
                listeningSignals.finish(itemId: item.id)
                marginOutput.noteCompletion(ofItem: item.id)
                saveCompletedSpokenNoteToExportFolder(item)
            }
            completionMarkingChanged(itemIds)
            if !result.changed.isEmpty || result.failure == nil {
                // Each completion as stored, so Undo clears only that one, never a later mark (`markUnfinished(markedAt:)`).
                let marks = result.changed.compactMap { item in item.sourceCompletedAt.map { (id: item.id, at: $0) } }
                let undo = bulkCompletionUndo(count: marks.count, action: .markFinished) { [weak self] in
                    self?.revertBulkCompletion(marks.map(\.id), as: .markUnfinished) { id in
                        guard let at = marks.first(where: { $0.id == id })?.at else { return nil }
                        return try ManualItemCompletion.markUnfinished(itemId: id, markedAt: at, in: store)
                    }
                }
                reportConfirmation(LibraryBulkAction.markFinished.banner(count: result.changed.count), action: undo)
            }
            if let failure = result.failure { reportFailure(failure, context: "Mark complete failed") }
        }
    }

    /// Mark as Unfinished: each item that was marked finished by hand. Natural completion is never undone. Undo marks
    /// exactly the items this changed finished again, at the time each was finished before.
    func markItemsUnfinished(_ itemIds: [String]) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_items_unfinished") else { return }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Mark unfinished failed"); return }
        Task { @MainActor [weak self] in
            let result = await Self.markCompletion(itemIds) { id -> (id: String, at: Date)? in
                let before = try store.loadItem(id: id).sourceCompletedAt
                guard try ManualItemCompletion.markUnfinished(itemId: id, markedAt: nil, in: store) != nil, let before else { return nil }
                return (id, before)
            }
            guard let self else { return }
            completionMarkingChanged(itemIds)
            if !result.changed.isEmpty || result.failure == nil {
                let marks = result.changed
                let undo = bulkCompletionUndo(count: marks.count, action: .markUnfinished) { [weak self] in
                    self?.revertBulkCompletion(marks.map(\.id), as: .markFinished) { id in
                        guard let at = marks.first(where: { $0.id == id })?.at else { return nil }
                        return try ManualItemCompletion.markComplete(itemId: id, at: at, in: store)
                    }
                }
                reportConfirmation(LibraryBulkAction.markUnfinished.banner(count: result.changed.count), action: undo)
            }
            if let failure = result.failure { reportFailure(failure, context: "Mark unfinished failed") }
        }
    }

    /// The Undo button on a bulk Mark banner, or nil when nothing changed.
    private func bulkCompletionUndo(
        count: Int, action: LibraryBulkAction, perform: @escaping @MainActor () -> Void
    ) -> UserFeedbackEvent.Action? {
        guard count > 0 else { return nil }
        return UserFeedbackEvent.Action(
            title: ManualCompletionMessages.undoTitle,
            accessibilityLabel: "\(ManualCompletionMessages.undoTitle): \(action.banner(count: count))",
            identifier: "library.bulk.completion.undo",
            perform: perform)
    }

    /// Takes a bulk Mark back on exactly the items it changed, off the main thread, with the opposite action's banner.
    private func revertBulkCompletion(
        _ itemIds: [String], as reverse: LibraryBulkAction, _ change: @escaping @Sendable (String) throws -> Item?
    ) {
        Task { @MainActor [weak self] in
            let result = await Self.markCompletion(itemIds, change)
            guard let self else { return }
            completionMarkingChanged(itemIds)
            if !result.changed.isEmpty { reportConfirmation(reverse.banner(count: result.changed.count)) }
            if let failure = result.failure { reportFailure(failure, context: "Undo failed") }
        }
    }

    /// Runs one item's change per ID off the main thread. An item that fails is skipped and the rest still change;
    /// the first failure is returned so it can be said once.
    nonisolated private static func markCompletion<Changed: Sendable>(
        _ itemIds: [String], _ change: @escaping @Sendable (String) throws -> Changed?
    ) async -> (changed: [Changed], failure: Error?) {
        await Task.detached(priority: .userInitiated) {
            var changed: [Changed] = []
            var failure: Error?
            for id in itemIds {
                do { if let item = try change(id) { changed.append(item) } } catch { failure = failure ?? error }
            }
            return (changed, failure)
        }.value
    }

    private func completionMarkingChanged(_ itemIds: [String]) {
        refreshLibraryRowsInBackground(mustPublish: true)
        if itemIds.contains(selectedItem.id) { refreshSelectedItemInBackground() }
    }

    /// Move to Recently Deleted for every ticked item, then one Undo that restores all that moved. An item that could not
    /// move is left where it is and said so; the rest still go.
    func moveItemsToTrash(_ itemIds: [String]) {
        guard !rejectNavigationOrSessionMutationWhileRecording("move_items_to_trash") else { return }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Move to Recently Deleted failed"); return }
        var moved: [(id: String, title: String)] = []
        var firstFailure: Error?
        for id in itemIds {
            do { moved.append((id, try trashItemQuietly(id: id, store: store))) } catch { firstFailure = firstFailure ?? error }
        }
        if let batch = LibraryTrashUndoBatch(moved: moved) {
            screen = .home
            presentTrashUndo(TrashUndoState(batch: batch))
            reportSuccess(LibraryBulkAction.moveToRecentlyDeleted.banner(count: batch.count))
        }
        if let firstFailure { reportFailure(firstFailure, context: "Move to Recently Deleted failed") }
    }

    /// A Select delete's Undo: every item it moved comes back, through the same restore as one row's.
    func restoreItems(_ batch: LibraryTrashUndoBatch) {
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Restore failed"); return }
        var restored: [String] = []
        var firstFailure: Error?
        for id in batch.itemIDs {
            do { _ = try restoreItemQuietly(id: id, store: store); restored.append(id) } catch { firstFailure = firstFailure ?? error }
        }
        refreshLibraryRowsInBackground(mustPublish: true)
        dismissTrashUndo()
        if !restored.isEmpty { reportSuccess(batch.restoredBanner(restoredIDs: restored)) }
        if let firstFailure { reportFailure(firstFailure, context: "Restore failed") }
    }

    /// Add to Collection with an existing collection: the items join at its end. Returns false when the save failed.
    @discardableResult
    func addItems(_ itemIds: [String], toCollection collection: ItemCollection) async -> Bool {
        guard let store else { reportFailure("The Library isn't ready yet."); return false }
        switch await libraryCollections.add(itemIds, toCollectionID: collection.id, store: store) {
        case .success(let added):
            collectionsChanged()
            reportConfirmation(LibraryBulkAction.collectionBanner(
                added: added, selected: Set(itemIds).count, name: collection.name, isNew: false))
            return true
        case .failure(let error):
            reportFailure(error, context: "Collection change failed")
            return false
        }
    }

    /// Add to Collection with a name typed in the same sheet: a new collection holding the items, in order. Returns the
    /// refusal to show under the name field (empty or taken), or nil once it is made.
    func addItems(_ itemIds: [String], toNewCollectionNamed name: String) async -> String? {
        guard let store else { reportFailure("The Library isn't ready yet."); return nil }
        switch await libraryCollections.create(name: name, itemIDs: itemIds, store: store) {
        case .saved:
            collectionsChanged()
            let trimmed = ItemCollectionEditing.normalizedName(name) ?? name
            reportConfirmation(LibraryBulkAction.collectionBanner(
                added: Set(itemIds).count, selected: Set(itemIds).count, name: trimmed, isNew: true))
            return nil
        case .needsName: return ItemCollectionEditing.Wording.nameRequired
        case .nameTaken: return ItemCollectionEditing.Wording.nameTaken
        case .failed(let error):
            reportFailure(error, context: "Collection change failed")
            return ItemCollectionEditing.Wording.saveFailed
        }
    }

    /// Remove from Collection, inside a collection's screen: the items stay in the Library with their Margins.
    func removeItems(_ itemIds: [String], fromCollection collection: ItemCollection) async {
        guard let store else { reportFailure("The Library isn't ready yet."); return }
        switch await libraryCollections.remove(itemIds, fromCollectionID: collection.id, store: store) {
        case .success(let removed):
            collectionsChanged()
            reportConfirmation(LibraryBulkAction.removeFromCollection.banner(count: removed, collectionName: collection.name))
        case .failure(let error):
            reportFailure(error, context: "Collection change failed")
        }
    }

    /// The Margins tab's collection scope follows a change to the collections.
    func collectionsChanged() {
        marginCollectionQuery.refreshCollection(from: libraryCollections.collections)
    }
}
