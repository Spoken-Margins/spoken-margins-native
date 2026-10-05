import Foundation

/// Followed articles whose extraction followed a redirect (#567). The Library item keeps the
/// page's final URL, because that is its sharing identity: a recipient's copy of the same article
/// is matched by it (J5). This file remembers which feed entry link led there, so I4 rows still
/// join that entry. It sits beside the log on the device, holds article links only (never feed
/// URLs), and is never exported.
public final class ListeningSignalRedirects: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(beside recorder: ListeningSignalRecorder) {
        self.init(fileURL: recorder.fileURL.deletingLastPathComponent()
            .appendingPathComponent("followed-article-redirects.json"))
    }

    /// Remembers that `entry`'s link ended at the handoff's URL, and returns the handoff unchanged.
    @discardableResult
    public func note(_ handoff: BrowserTextHandoff, for entry: FeedEntry) -> BrowserTextHandoff {
        guard let final = FollowedSourceMatching.normalizedFollowSourceURL(handoff.source.url),
              let origin = FollowedSourceMatching.normalizedFollowSourceURL(entry.canonicalURL),
              final != origin else { return handoff }
        lock.withLock {
            var map = loadLocked()
            guard map[final] != origin else { return }
            map[final] = origin
            cache = map
            if let data = try? JSONEncoder().encode(map) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        return handoff
    }

    /// Normalized final URL to the normalized feed entry link that led to it.
    public func origins() -> [String: String] {
        lock.withLock { loadLocked() }
    }

    private func loadLocked() -> [String: String] {
        if let cache { return cache }
        let map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = map
        return map
    }
}
