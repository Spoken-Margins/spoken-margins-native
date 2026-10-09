import Foundation
import SessionKit
import SessionKitSharing

/// Adds the article a shared packet is about when the listener doesn't have it, so the Margins have a source (#916).
extension Gate1AppModel {
    /// The article a packet links to, fetched and added; anything else the listener lacks is a sentence, not an orphan layer.
    func acquireArticleForImportedPackage(_ item: SharedItemIdentity) async throws -> String {
        guard let url = SharedArticleReferencePolicy.articleURL(for: item) else {
            // A layer saved with no item reports success but can't play. Say so instead.
            throw SessionKitError.persistenceFailed("shared_item_not_in_library")
        }
        return try await fetchArticleForImportedPackage(url)
    }

    /// Reads the shared article from its link and adds it to the Library without touching Now Playing.
    private func fetchArticleForImportedPackage(_ url: URL) async throws -> String {
        let handoff: BrowserTextHandoff
        do {
            handoff = try await readablePageExtractor.extract(url: url)
        } catch {
            if error is URLError { throw error } // offline and timeouts get the connection message
            diagnostics["lastSharedArticleAcquisition"] = "failed:\(error.localizedDescription)"
            throw SessionKitError.persistenceFailed("shared_article_unreadable")
        }
        diagnostics["lastSharedArticleAcquisition"] = "fetched:\(url.absoluteString)"
        return try importBrowserTextInBackground(handoff)
    }
}
