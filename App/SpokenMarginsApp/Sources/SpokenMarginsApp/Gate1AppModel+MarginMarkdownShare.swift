import Foundation
import SessionKit

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    /// "Share as Markdown" (#493): the notes-folder note of one Margin, or of an item's Margins, as a
    /// named `.md` file in a temporary folder, for the share sheet.
    func marginMarkdownFileURL(for margins: [Interjection], asItem: Bool) -> URL? {
        // An item made from a live session shares the session's own Markdown, with its position evidence (#2481).
        if asItem, let itemId = margins.first?.itemId, let url = liveSessionMarkdownFileURL(itemId: itemId, margins: margins) { return url }
        var url: URL?
        run { engine in
            let file = asItem ? try MarginMarkdownShare.file(forItemMargins: margins, engine: engine)
                : try margins.first.flatMap { try MarginMarkdownShare.file(for: $0, engine: engine) }
            guard let file else { return reportFailure("There's no written or transcribed Margin to share yet.") }
            url = try MarginMarkdownShare.write(file, under: MarginMarkdownShare.shareDirectory)
        }
        return url
    }
}

extension MarginMarkdownShare {
    /// Each share's file sits in its own folder here until its share sheet closes. iPad windows
    /// can each have a share sheet open, so a new share never clears the others' files.
    static var shareDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MarginMarkdown", isDirectory: true)
    }

    /// Removes one share's folder once its sheet has closed. Leaves any other file alone.
    static func discardShare(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == shareDirectory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
