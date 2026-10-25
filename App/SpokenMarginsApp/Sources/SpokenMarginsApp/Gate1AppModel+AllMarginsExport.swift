import Foundation
import SessionKit

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    /// "Export all Margins" (#1866): every Margin the listener has, item by item, newest item first, as one
    /// Markdown file for the share sheet. Not narrowed by the search or filters, so "all" means all.
    func allMarginsMarkdownFileURL() -> URL? {
        let entries = marginRows.map { MarginGroupOrdering.Entry(itemID: $0.interjection.itemId, createdAt: $0.interjection.createdAt) }
        let byItem = Dictionary(grouping: marginRows.map(\.interjection), by: \.itemId)
        let ordered = MarginGroupOrdering.groups(from: entries).compactMap { byItem[$0.itemID] }
        var url: URL?
        run { engine in
            guard let file = try MarginMarkdownShare.file(forAllMargins: ordered, engine: engine) else {
                return reportFailure("There's no written or transcribed Margin to export yet.")
            }
            url = try MarginMarkdownShare.write(file, under: MarginMarkdownShare.shareDirectory)
        }
        return url
    }
}
