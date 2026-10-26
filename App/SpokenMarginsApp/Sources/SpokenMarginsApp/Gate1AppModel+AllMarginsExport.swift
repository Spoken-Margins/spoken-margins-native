import Foundation
import SessionKit
import SessionKitPersistence

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    /// "Export all Margins" (#1866): every Margin the listener has, item by item, newest item first, as one
    /// Markdown file for the share sheet. Not narrowed by the search or filters, so "all" means all.
    /// The state is copied on the main actor; the store reads and the file write run off it, so a large Library
    /// never freezes the screen (#2256). The button shows its progress meanwhile.
    func prepareAllMarginsMarkdownFileURL() async -> URL? {
        let entries = marginRows.map { MarginGroupOrdering.Entry(itemID: $0.interjection.itemId, createdAt: $0.interjection.createdAt) }
        let byItem = Dictionary(grouping: marginRows.map(\.interjection), by: \.itemId)
        let ordered = MarginGroupOrdering.groups(from: entries).compactMap { byItem[$0.itemID] }
        // Make sure the engine exists, then borrow only its profile; the export builds its own engine below.
        _ = run { _ in }
        guard let store, let profile = engine?.profile else {
            reportFailure("Margins can't be exported right now.")
            return nil
        }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL?, Error> in
            Result {
                let exportEngine = SessionEngine(profile: profile, repository: store)
                guard let file = try MarginMarkdownShare.file(forAllMargins: ordered, engine: exportEngine) else { return nil }
                return try MarginMarkdownShare.write(file, under: MarginMarkdownShare.shareDirectory)
            }
        }.value
        switch outcome {
        case .success(let url):
            if url == nil { reportFailure("There's no written or transcribed Margin to export yet.") }
            return url
        case .failure(let error):
            reportFailure("Export all Margins failed: \(error.localizedDescription)")
            return nil
        }
    }
}
