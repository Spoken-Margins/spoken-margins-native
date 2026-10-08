import Foundation

/// The feed entry each followed article was imported from (#567). The Library item keeps the
/// page's final URL, because that is its sharing identity: a recipient's copy of the same article
/// is matched by it (J5). Its URL alone can't always name the entry: extraction may have followed a
/// redirect, and two followed feeds (a publication's main feed and a topic feed) can list the same
/// article. This file remembers the entry the listener picked, so I4 rows still join it. It sits
/// beside the log on the device, holds article links and entry ids only (never feed URLs), and is
/// never exported.
public final class ListeningSignalImportedEntries: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(beside recorder: ListeningSignalRecorder) {
        self.init(fileURL: recorder.fileURL.deletingLastPathComponent()
            .appendingPathComponent("followed-article-entries.json"))
    }

    /// Remembers that the handoff's article came from `entry`, and returns the handoff unchanged.
    @discardableResult
    public func note(_ handoff: BrowserTextHandoff, for entry: FeedEntry) -> BrowserTextHandoff {
        guard let url = FollowedSourceMatching.normalizedFollowSourceURL(handoff.source.url) else { return handoff }
        lock.withLock {
            var map = loadLocked()
            guard map[url] != entry.id else { return }
            map[url] = entry.id
            cache = map
            if let data = try? JSONEncoder().encode(map) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        return handoff
    }

    /// Normalized article URL to the id of the feed entry it was imported from.
    public func entryIds() -> [String: String] {
        lock.withLock { loadLocked() }
    }

    private func loadLocked() -> [String: String] {
        if let cache { return cache }
        let map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = map
        return map
    }
}
