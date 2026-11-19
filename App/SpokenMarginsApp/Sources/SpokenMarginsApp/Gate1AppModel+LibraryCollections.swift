import Foundation
import SessionKit

/// The Library as narrowed by the collection chip (#4343). The collections and the selection live in
/// `LibraryCollectionModel`; these are the model's reads of them.
extension Gate1AppModel {
    /// What the Library lists: the selected collection's rows, then the listener's filter, sort and search.
    var visibleLibraryItems: [LibraryItemRow] {
        LibraryCollectionScope.visibleLibraryItems(libraryItems, query: libraryQuery, in: libraryCollections.selection)
    }

    /// What "Completed hidden" adds when the finished items it hides hold a friend's Margins (#3794), or nil.
    var libraryCompletedHiddenNote: String? {
        LibraryQueryEngine.completedHiddenNote(LibraryCollectionScope.rows(libraryItems, in: libraryCollections.selection), query: libraryQuery)
    }

    /// Whether every row in scope is finished, read over the collection's own rows when one is selected.
    var libraryIsCaughtUp: Bool {
        LibraryQueryEngine.libraryIsCaughtUp(LibraryCollectionScope.rows(libraryItems, in: libraryCollections.selection), query: libraryQuery)
    }

    /// Connects the collections to the model at launch, so its views redraw when the selection changes.
    func wireLibraryCollections() {
        libraryCollections.forwardWillChange(to: objectWillChange)
        // A save or delete here stales any Library read already in flight, which carries the collections as they were.
        libraryCollections.onLocalWrite = { [weak self] in self?.libraryPresentationRevision += 1 }
    }
}
