import Foundation
import SessionKit

/// What a collection row and the collection screen do (#3769): Play All / Continue / Play Again, play from one item,
/// Add to Queue, Export Margins, Rename and Delete Collection. Where each starts and what it queues is
/// `LibraryCollectionPlayPlan` and `LibraryCollectionQueueing`; these run them.
extension Gate1AppModel {
    /// Puts the plan's following items in front of the queue, then starts its start item the way a row's play does, so a
    /// friend's new Margins can still be offered first.
    func playCollection(_ plan: LibraryCollectionPlayPlan, name: String, offer: (NewMarginsOfferRequest) -> Void) {
        PlayQueueController.update(self) { $0.playNext(contentsOf: plan.queuedItemIDs) }
        continueListening(itemId: plan.startItemID, offer: offer)
        reportConfirmation(plan.banner(name: name))
    }

    /// Add to Queue on a whole collection: its unfinished items at the end of the queue (all of them once every one is
    /// finished). Items already queued keep their place and are not counted.
    func queueCollection(_ progress: LibraryCollectionProgress) {
        let ids = LibraryCollectionQueueing.itemsToQueue(progress)
        var added = 0
        PlayQueueController.update(self) { added = $0.append(contentsOf: ids) }
        reportConfirmation(LibraryCollectionQueueing.banner(added: added, name: progress.name))
    }

    /// Export Margins with the collection's sessions ticked, through the Library's own export.
    func exportCollectionMargins(collectionID: String) {
        guard let collection = libraryCollections.collections.first(where: { $0.id == collectionID }) else { return }
        openBatchExport(scopedTo: ItemCollectionScope(collection))
    }

    /// Rename a collection. Returns the refusal to show (empty or taken name, or a failed save), or nil once renamed.
    func renameCollection(collectionID: String, to name: String) async -> String? {
        guard let store, let collection = libraryCollections.collections.first(where: { $0.id == collectionID }) else { return nil }
        switch await libraryCollections.rename(collection, to: name, store: store) {
        case .saved:
            collectionsChanged()
            return nil
        case .needsName, .nameTaken:
            return ItemCollectionEditing.Wording.renameRefused
        case .failed(let error):
            reportFailure(error, context: "Collection change failed")
            return ItemCollectionEditing.Wording.saveFailed
        }
    }

    /// Delete Collection: the collection goes, and every item and Margin in it stays in the Library. `quiet` leaves the
    /// confirmation out, for Undo of a link list that already says what it did (#4683).
    @discardableResult
    func deleteCollection(collectionID: String, quiet: Bool = false) async -> Bool {
        guard let store, let collection = libraryCollections.collections.first(where: { $0.id == collectionID }) else { return false }
        switch await libraryCollections.delete(collection, store: store) {
        case .saved:
            collectionsChanged()
            if !quiet { reportConfirmation("Deleted “\(collection.name)”. Everything in it is still in your Library.") }
            return true
        case .failed(let error):
            reportFailure(error, context: "Collection change failed")
            return false
        case .needsName, .nameTaken:
            return false
        }
    }
}
