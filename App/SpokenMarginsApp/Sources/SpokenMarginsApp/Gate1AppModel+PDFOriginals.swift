import Foundation
import SessionKit
import SessionKitPersistence

/// Keeping the original PDF beside its item (#4338). Every PDF import path holds the file's bytes until the item's id is
/// known and then writes them here, so a later export can put the listener's Margins into a copy of the file. The store
/// itself (`PDFOriginalStore`) and its tests are in SessionKit; this is only where the app finds its folder and calls it.
extension Gate1AppModel {
    /// The store over `ItemOriginals/` under Application Support, the folder permanent delete also purges.
    func pdfOriginalStore() throws -> PDFOriginalStore {
        Self.pdfOriginalStore(applicationSupport: try applicationSupportDirectory())
    }

    nonisolated static func pdfOriginalStore(applicationSupport: URL) -> PDFOriginalStore {
        PDFOriginalStore(root: applicationSupport.appending(path: ItemOwnedFiles.itemOriginalsRoot, directoryHint: .isDirectory))
    }

    /// Keeps `data` as the original of item `itemId`, off the main thread. A failure is only noted in diagnostics: the
    /// import already succeeded, and an item with no kept file is the "Original missing" case the export screen handles.
    func keepOriginalPDF(_ data: Data, itemId: String) async {
        do {
            let store = try pdfOriginalStore()
            try await Self.offMain { try store.write(data, itemId: itemId); return () }
            diagnostics["lastPDFOriginalKept"] = itemId
        } catch {
            diagnostics["lastPDFOriginalKeepFailure"] = SafeErrorText.describe(error)
        }
    }

    /// The item's kept original and what kind it is (a PDF or a Word document), or nil when this iPhone has none. A file
    /// lookup, so it runs off the main thread (the item screen asks it which export entry to offer, #4595).
    func keptOriginal(itemId: String) async -> (url: URL, kind: ItemOriginalStore.Kind)? {
        guard let store = try? pdfOriginalStore() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> (url: URL, kind: ItemOriginalStore.Kind)? in
            guard let kind = store.kind(itemId: itemId), let url = store.url(itemId: itemId) else { return nil }
            return (url, kind)
        }.value
    }

    /// Keeps a copy of the file at `url` as the original of item `itemId`, off the main thread and a chunk at a time, so no
    /// import ever holds a PDF's bytes. `expectedSHA256` is the hash the item's document recorded; a file that changed since
    /// is not kept (the copy would not be the file the text came from). A failure is only noted in diagnostics.
    func keepOriginalPDF(copying url: URL, itemId: String, expectedSHA256: String?) async {
        do {
            let store = try pdfOriginalStore()
            try await Self.offMain {
                let staged = try store.stage(copying: url, itemId: itemId)
                if let expectedSHA256, staged.sha256 != expectedSHA256 {
                    store.discard(staged)
                    throw CocoaError(.fileReadCorruptFile)
                }
                try store.commit(staged)
                return ()
            }
            diagnostics["lastPDFOriginalKept"] = itemId
        } catch {
            diagnostics["lastPDFOriginalKeepFailure"] = SafeErrorText.describe(error)
        }
    }

    /// Clears the temporary files a quit left in `ItemOriginals/`, off the main thread. It never touches a kept PDF, and
    /// only a temporary file untouched for ten minutes, so an import running now is safe.
    func removeInterruptedPDFOriginalWrites() {
        guard let store = try? pdfOriginalStore() else { return }
        Task.detached(priority: .utility) { store.removeInterruptedWrites() }
    }
}
