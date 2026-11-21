import Foundation
import SessionKit
import SessionKitPersistence

/// Where a PDF's table and figure pictures are kept, and the save that follows a PDF import (#3895).
extension Gate1AppModel {
    /// `SpokenMargins/PDFClips/` under Application Support, or nil when the support folder can't be found.
    func pdfClipStore() -> PDFClipStore? {
        (try? applicationSupportDirectory()).map(Self.pdfClipStore(support:))
    }

    nonisolated static func pdfClipStore(support: URL) -> PDFClipStore {
        PDFClipStore(directory: support.appending(path: "SpokenMargins/\(ItemOwnedFiles.pdfClipsRoot)", directoryHint: .isDirectory))
    }

    /// Saves the pictures cut from a PDF under the item the import ended with, off the main thread. Only the floats of
    /// the document the item now stores get one, so an import that kept an older document saves nothing that doesn't
    /// belong to it. Best effort: no clip is ever a reason for an import to fail, and a row without one shows its text.
    func savePDFClips(_ clips: [String: Data], itemId: String) async {
        guard let store, let clipStore = pdfClipStore() else { return }
        let saved = await Task.detached(priority: .utility) { () -> Bool in
            let document = try? store.loadStructuredDocument(itemId: itemId)
            return (try? clipStore.replaceClips(clips, forItem: itemId, document: document)) != nil
        }.value
        // A Now tab already open on this item listed its clips before they existed; it lists them again (#4588).
        if saved {
            NotificationCenter.default.post(
                name: PDFClipStore.didSaveClipsNotification, object: nil,
                userInfo: [PDFClipStore.itemIdKey: itemId])
        }
    }
}
