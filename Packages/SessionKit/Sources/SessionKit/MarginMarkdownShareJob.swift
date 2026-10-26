import Foundation

extension MarginMarkdownShare {
    /// The live session's Markdown file could not be written (#2481). Kept apart from the ordinary export's
    /// errors so the app can say which export failed.
    public struct LiveSessionExportFailure: Error {
        public let underlying: Error
    }

    /// Everything "Share as Markdown" (#493) does between the tap and the share sheet, in one call that holds no
    /// main-actor state: the live session's record and the store reads (`engine`), then the file write. The app runs it
    /// on a background task so a big item never freezes the tap (#2256).
    ///
    /// - Returns: the file's URL, or nil when no Margin has a note to share.
    /// - Throws: `LiveSessionExportFailure` when the live session's file can't be written; any other error comes
    ///   from the ordinary export.
    public static func prepare(
        margins: [Interjection], asItem: Bool, engine: SessionEngine, liveSessionDirectory: URL?, under directory: URL
    ) throws -> URL? {
        // An item made from a live session shares the session's own Markdown, with its position evidence (#2481).
        if asItem, let itemId = margins.first?.itemId, let liveSessionDirectory,
           let saved = LiveSessionRecord.load(itemId: itemId, from: liveSessionDirectory),
           let record = saved.current(margins.filter { $0.itemId == itemId }.compactMap(LiveSessionRecord.CurrentMargin.init)) {
            do { return try writeLiveSession(record, under: directory) } catch { throw LiveSessionExportFailure(underlying: error) }
        }
        let shared = asItem ? try file(forItemMargins: margins, engine: engine)
            : try margins.first.flatMap { try file(for: $0, engine: engine) }
        return try shared.map { try write($0, under: directory) }
    }

    private static func writeLiveSession(_ record: LiveSessionRecord, under directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = record.session.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let url = folder.appendingPathComponent((name.isEmpty ? "Live session" : name) + ".md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LiveSessionMarkdown.render(record).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
