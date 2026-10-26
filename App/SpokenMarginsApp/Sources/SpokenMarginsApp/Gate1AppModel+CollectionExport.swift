import SessionKit
import SessionKitPersistence

extension Gate1AppModel {
    /// Opens Export Sessions. With a collection in scope (#490), only that collection's sessions that the default
    /// "With Margins" list shows start selected; with none, nothing does.
    ///
    /// The list's rows are read off the main actor (#2507), so the screen appears when they are ready, a beat after
    /// the tap; the returned task finishes then. A second open cancels the first, so an old read can't replace a
    /// newer one.
    @discardableResult
    func openBatchExport(scopedTo collection: ItemCollectionScope?) -> Task<Void, Never> {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_batch_export") else { return Task {} }
        syncPlaybackProgressForLifecycle()
        exportSessionId = nil
        exportPreview = ""
        batchExportFilter = .withInterjections
        selectedBatchExportSessionIds = []
        batchExportResult = nil
        // A share whose sheet was torn down with the screen: remove its files and let Export work again.
        batchExportShare?.discard()
        batchExportShare = nil
        let store: SQLiteSessionStore
        do {
            store = try requireStore()
        } catch {
            reportFailure(error, context: "Session export setup failed")
            return Task {}
        }
        batchExportLoadTask?.cancel()
        let openedFrom = screen
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let rows = try await StoreReader(store).read(priority: .userInitiated) { try $0.loadBatchExportRows() }
                // The listener moved on, or started recording, while the rows were read: don't pull them back.
                guard !Task.isCancelled, screen == openedFrom, !snapshot.isRecording else { return }
                hangTelemetry.labels.scoped("batchExportOpened") {
                    batchExportRows = rows
                    selectedBatchExportSessionIds.formIntersection(Set(rows.map(\.id)))
                    if let collection {
                        selectedBatchExportSessionIds = Set(visibleBatchExportRows
                            .filter { collection.contains(itemID: $0.session.itemId) }.map(\.id))
                    }
                    screen = .batchExport
                }
            } catch is CancellationError {
                return
            } catch {
                reportFailure(error, context: "Session export setup failed")
            }
        }
        batchExportLoadTask = task
        return task
    }
}
