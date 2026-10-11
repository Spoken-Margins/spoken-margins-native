import Foundation

/// Resolves followed-item context and enqueues I4 signals off the playback/UI thread.
/// All context/cache work is confined to one utility queue. Capturing time before enqueueing
/// keeps a slow repository from inflating or shifting listening intervals.
public final class ListeningSignalCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SessionKit.ListeningSignalCollector", qos: .utility)
    private let recorder: ListeningSignalRecorder
    /// Where followed-article imports note their feed entry, beside the recorder's log.
    public let importedEntries: ListeningSignalImportedEntries
    private let resolve: @Sendable (String, any SessionRepository) -> ListeningSignalContext.Value?
    private var cachedItemId: String?
    private var cachedRepository: (any SessionRepository)?
    private var cachedContext: ListeningSignalContext.Value?
    private var cachedSubscriptions: [FeedSubscription]?
    private var cachedItemKey: ItemKey?
    /// The repository's revision of the item when `cachedItemKey` was read. While it stands still
    /// the item is not read again, so a long article or PDF is not decoded twice a second.
    private var cachedItemRevision: Int?

    /// The item fields `ListeningSignalContext` reads to find the followed source and feed entry.
    /// An item can gain a source link while the subscriptions stay as they were (#1340), so the
    /// cache keys on these too. Everything else on the item, its text included, is ignored.
    private struct ItemKey: Equatable {
        var title: String
        var externalReference: String?
        var sourceTitle: String?
        var sourceURL: String?
        var mediaURL: String?
        var durationMs: Int?
        var episodeGUID: String?
        var createdAt: Date?

        init(_ item: Item) {
            title = item.title
            externalReference = item.externalReference
            sourceTitle = item.sourceTitle
            sourceURL = item.sourceURL
            mediaURL = item.media?.url
            durationMs = item.media?.durationMs
            episodeGUID = item.episodeGUID
            createdAt = item.createdAt
        }
    }

    public convenience init(recorder: ListeningSignalRecorder) {
        let importedEntries = ListeningSignalImportedEntries(beside: recorder)
        self.init(recorder: recorder, importedEntries: importedEntries, resolve: {
            ListeningSignalContext.load(forItemId: $0, from: $1, importedEntryIds: importedEntries.entryIds())
        })
    }

    public init(recorder: ListeningSignalRecorder,
                importedEntries: ListeningSignalImportedEntries? = nil,
                resolve: @escaping @Sendable (String, any SessionRepository) -> ListeningSignalContext.Value?) {
        self.recorder = recorder
        self.importedEntries = importedEntries ?? ListeningSignalImportedEntries(beside: recorder)
        self.resolve = resolve
    }

    /// `transport` is the player's own state. While it waits (a network stall) the session still
    /// reads as playing, so a waiting tick neither extends nor closes the interval: a stall longer
    /// than the recorder's gap splits it, and a brief wait between sentences stays inside it.
    public func playbackProgress(itemId: String?, status: PlaybackStatus, transport: PlaybackTransportState? = nil,
                                 repository: (any SessionRepository)?, at: Date = Date()) {
        queue.async {
            guard status == .playing, let itemId, let repository else {
                self.closeListening()
                return
            }
            guard transport != .waiting else { return }
            // Subscription mutations can happen through any follow/unfollow caller, while the
            // item and repository stay the same. Detect them here, off the playback thread,
            // while retaining the more expensive item/feed-entry resolution during steady ticks.
            guard let subscriptions = try? repository.loadFeedSubscriptions() else {
                self.closeListening()
                return
            }
            // The item's own source fields can change too (a link added, a Library item matched to
            // a feed you already follow), with the subscriptions untouched, so they are keyed as well.
            // The item is read only when its repository says it was written since the last read (a
            // repository that can't say is read every tick). A read that fails once keeps the last
            // key and tries again next tick, so a hiccup doesn't split the interval.
            let revision = (repository as? ItemRevisionReading)?.itemRevision(id: itemId)
            let unchanged = revision != nil && revision == self.cachedItemRevision
                && self.cachedItemId == itemId && self.cachedRepository === repository
            var itemKey = self.cachedItemKey
            if !unchanged, let item = try? repository.loadItem(id: itemId) {
                itemKey = ItemKey(item)
                self.cachedItemRevision = revision
            }
            if self.cachedItemId != itemId || self.cachedRepository !== repository
                || self.cachedSubscriptions != subscriptions || self.cachedItemKey != itemKey {
                self.recorder.endListening()
                self.cachedContext = self.resolve(itemId, repository)
                self.cachedItemId = itemId
                self.cachedRepository = repository
                self.cachedSubscriptions = subscriptions
                self.cachedItemKey = itemKey
            }
            guard let context = self.cachedContext else { return }
            self.recorder.noteListening(source: context.source, item: context.item, at: at)
        }
    }

    public func endListening() {
        queue.async { self.closeListening() }
    }

    public func record(_ event: ListeningSignalEvent, itemId: String?,
                       repository: (any SessionRepository)?, at: Date = Date()) {
        queue.async {
            // An item without a followed source logs no row, but the packet is still ours (#867).
            if case .export(let packetId?, _) = event { self.recorder.noteExportedPacket(packetId) }
            guard let itemId, let repository, let context = self.resolve(itemId, repository) else { return }
            self.recorder.record(event, source: context.source, item: context.item, at: at)
        }
    }

    public func packetImport(itemId: String?, packetId: String, marginCount: Int,
                             repository: (any SessionRepository)?, at: Date = Date()) {
        queue.async {
            guard let itemId, let repository, let context = self.resolve(itemId, repository) else { return }
            self.recorder.recordPacketImport(packetId: packetId, marginCount: marginCount,
                                             source: context.source, item: context.item, at: at)
        }
    }

    public func dismiss(entryId: String, repository: (any SessionRepository)?, at: Date = Date()) {
        queue.async {
            guard let repository,
                  let context = ListeningSignalContext.context(forEntryId: entryId,
                    entries: (try? repository.loadFeedEntries(subscriptionId: nil)) ?? [],
                    subscriptions: (try? repository.loadFeedSubscriptions()) ?? [], seenAt: at) else { return }
            self.recorder.record(.dismiss, source: context.source, item: context.item, at: at)
        }
    }

    /// Explicit export and tests wait for queued context work before asking the recorder to flush.
    public func flush() {
        queue.sync {}
        recorder.flush()
    }

    public func exportCopy(to directory: URL) throws -> URL? {
        queue.sync {}
        return try recorder.exportCopy(to: directory)
    }

    private func closeListening() {
        recorder.endListening()
        cachedItemId = nil
        cachedRepository = nil
        cachedContext = nil
        cachedSubscriptions = nil
        cachedItemKey = nil
        cachedItemRevision = nil
    }
}
