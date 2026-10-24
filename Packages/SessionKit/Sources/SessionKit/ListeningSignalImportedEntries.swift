import Foundation

/// The feed entry each followed article was imported from (#567). The Library item keeps the
/// page's final URL, because that is its sharing identity: a recipient's copy of the same article
/// is matched by it (J5). Its URL alone can't always name the entry: extraction may have followed a
/// redirect, and two followed feeds (a publication's main feed and a topic feed) can list the same
/// article. This file remembers the entry the listener picked, so I4 rows still join it. It sits
/// beside the log on the device, holds article links and entry ids only (never feed URLs), and is
/// never exported.
///
/// The map is read and written on a private serial queue, never on the caller's thread (#2509). A tap on
/// Add, Open or Play only enqueues the note; `entryIds()` waits for the notes ahead of it, so a reader
/// (this instance or a fresh one, as after a relaunch) always sees every note made before it was called.
public final class ListeningSignalImportedEntries: @unchecked Sendable {
    public let fileURL: URL
    /// One queue for every instance: a fresh instance's first read waits behind any note still being written.
    private static let queue = DispatchQueue(label: "com.spokenmargins.followed-article-entries", qos: .utility)
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
        if let url = FollowedSourceMatching.normalizedFollowSourceURL(handoff.source.url) {
            store(key: url, entryId: entry.id)
        }
        return handoff
    }

    /// Remembers that the Library item `itemId` was imported from `entry`. The URL record above
    /// belongs to whichever import came last, so a second edition of the same article (from another
    /// feed, or after the text changed) would take over the first edition's entry; the item id
    /// names exactly one edition (#865).
    public func note(itemId: String, for entry: FeedEntry) {
        store(key: Self.itemKey(itemId), entryId: entry.id)
    }

    /// The key an imported Library item is recorded under. A normalized article URL always starts
    /// with its scheme, so the two kinds of key never meet in the one map.
    public static func itemKey(_ itemId: String) -> String { "item:\(itemId)" }

    private func store(key: String, entryId: String) {
        Self.queue.async { [self] in
            var map = loadOnQueue()
            guard map[key] != entryId else { return }
            map[key] = entryId
            cache = map
            if let data = try? JSONEncoder().encode(map) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Normalized article URL, or `itemKey(_:)` of an imported Library item, to the id of the feed
    /// entry it was imported from.
    public func entryIds() -> [String: String] {
        Self.queue.sync { loadOnQueue() }
    }

    private func loadOnQueue() -> [String: String] {
        if let cache { return cache }
        let map = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = map
        return map
    }
}
