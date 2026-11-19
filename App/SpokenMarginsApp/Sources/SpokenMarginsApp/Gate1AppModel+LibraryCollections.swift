import Foundation
import SessionKit

/// The Library's lists with collections (#3769). The collections and the Collections | All Items choice live in
/// `LibraryCollectionModel`; the rules are `LibraryCollectionListEngine`. These are the model's reads of them.
extension Gate1AppModel {
    /// Every item row the Library's filter, sort and search keep, flat (the All Items view's rows).
    var visibleLibraryItems: [LibraryItemRow] {
        LibraryQueryEngine.visibleLibraryItems(libraryItems, query: libraryQuery)
    }

    /// What the Library lists in the current view: collection rows and item rows, the Continue row first.
    func libraryListing(currentItemID: String?) -> [LibraryListing] {
        LibraryCollectionListEngine.listing(
            rows: libraryItems, collections: libraryCollections.collections, imported: libraryCollections.folders,
            query: libraryQuery, mode: libraryCollections.viewMode, currentItemID: currentItemID)
    }

    /// Every collection as a row, alphabetical: the collection screen and Add to Collection read these.
    var libraryCollectionRows: [LibraryCollectionRow] {
        LibraryCollectionListEngine.collectionRows(
            rows: libraryItems, collections: libraryCollections.collections, imported: libraryCollections.folders)
    }

    /// How many finished items the listening filter hides, for the line at the end of the Library (#4698).
    var libraryCompletedHiddenCount: Int {
        LibraryQueryEngine.completedHiddenCount(libraryItems, query: libraryQuery)
    }

    /// Whether the default view has nothing left to do, with a collection counted as one row in the Collections view.
    var libraryIsCaughtUp: Bool {
        LibraryCollectionListEngine.isCaughtUp(
            rows: libraryItems, collections: libraryCollections.collections, imported: libraryCollections.folders,
            query: libraryQuery, mode: libraryCollections.viewMode)
    }

    /// Connects the collections to the model at launch, so its views redraw when they or the view choice change.
    func wireLibraryCollections() {
        libraryCollections.forwardWillChange(to: objectWillChange)
        // A save or delete here stales any Library read already in flight, which carries the collections as they were.
        libraryCollections.onLocalWrite = { [weak self] in self?.libraryPresentationRevision += 1 }
    }
}
