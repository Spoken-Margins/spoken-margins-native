import Foundation
import SessionKit
import SessionKitPersistence

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    /// "Share as Markdown" (#493): the notes-folder note of one Margin, or of an item's Margins, as a
    /// named `.md` file in a temporary folder, for the share sheet. The store reads and the file write run
    /// off the main actor (#2256), as in Export all Margins; the caller shows progress meanwhile. Nil when
    /// there is nothing to share, after saying why.
    func prepareMarginMarkdownFileURL(for margins: [Interjection], asItem: Bool) async -> URL? {
        // Make sure the engine exists, then borrow only its profile; the export builds its own engine below.
        _ = run { _ in }
        guard let store, let profile = engine?.profile else {
            reportFailure("Margins can't be shared right now.")
            return nil
        }
        let liveSessionDirectory = Self.liveSessionDirectory
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL?, Error> in
            Result {
                try MarginMarkdownShare.prepare(
                    margins: margins, asItem: asItem, engine: SessionEngine(profile: profile, repository: store),
                    liveSessionDirectory: liveSessionDirectory, under: MarginMarkdownShare.shareDirectory)
            }
        }.value
        switch outcome {
        case .success(let url):
            if url == nil { reportFailure("There's no written or transcribed Margin to share yet.") }
            return url
        case .failure(let error as MarginMarkdownShare.LiveSessionExportFailure):
            reportFailure(error.underlying, context: "Live session export failed", itemId: margins.first?.itemId)
            return nil
        case .failure(let error):
            reportFailure(error)
            return nil
        }
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
