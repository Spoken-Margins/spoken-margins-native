import Foundation
import SessionKit

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    /// "Share as Markdown" (#493): the notes-folder note of one Margin, or of an item's Margins, as a
    /// named `.md` file in a temporary folder, for the share sheet.
    func marginMarkdownFileURL(for margins: [Interjection], asItem: Bool) -> URL? {
        var url: URL?
        run { engine in
            let file = asItem ? try MarginMarkdownShare.file(forItemMargins: margins, engine: engine)
                : try margins.first.flatMap { try MarginMarkdownShare.file(for: $0, engine: engine) }
            guard let file else { return reportFailure("There's no written or transcribed Margin to share yet.") }
            // One share sheet at a time, so the previous share's file can go.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarginMarkdown", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            url = try MarginMarkdownShare.write(file, under: directory)
        }
        return url
    }
}
