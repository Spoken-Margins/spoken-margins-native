import SessionKit

extension Gate1AppModel {
    /// Opens batch export. With a collection in scope (#490), only that collection's sessions that the default
    /// "With Margins" list shows start selected; with none, it opens exactly as `openBatchExport()` does.
    func openBatchExport(scopedTo collection: ItemCollectionScope?) {
        openBatchExport()
        guard let collection, screen == .batchExport else { return }
        selectedBatchExportSessionIds = Set(visibleBatchExportRows
            .filter { collection.contains(itemID: $0.session.itemId) }.map(\.id))
    }
}
