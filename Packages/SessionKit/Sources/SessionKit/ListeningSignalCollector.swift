import Foundation

/// Resolves followed-item context and enqueues I4 signals off the playback/UI thread.
/// All context/cache work is confined to one utility queue. Capturing time before enqueueing
/// keeps a slow repository from inflating or shifting listening intervals.
public final class ListeningSignalCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SessionKit.ListeningSignalCollector", qos: .utility)
    private let recorder: ListeningSignalRecorder
    private let resolve: @Sendable (String, any SessionRepository) -> ListeningSignalContext.Value?
    private var cachedItemId: String?
    private var cachedRepository: (any SessionRepository)?
    private var cachedContext: ListeningSignalContext.Value?
    private var cachedSubscriptions: [FeedSubscription]?

    public init(recorder: ListeningSignalRecorder,
                resolve: @escaping @Sendable (String, any SessionRepository) -> ListeningSignalContext.Value? = {
                    ListeningSignalContext.load(forItemId: $0, from: $1)
                }) {
        self.recorder = recorder
        self.resolve = resolve
    }

    public func playbackProgress(itemId: String?, status: PlaybackStatus,
                                 repository: (any SessionRepository)?, at: Date = Date()) {
        queue.async {
            guard status == .playing, let itemId, let repository else {
                self.closeListening()
                return
            }
            // Subscription mutations can happen through any follow/unfollow caller, while the
            // item and repository stay the same. Detect them here, off the playback thread,
            // while retaining the more expensive item/feed-entry resolution during steady ticks.
            guard let subscriptions = try? repository.loadFeedSubscriptions() else {
                self.closeListening()
                return
            }
            if self.cachedItemId != itemId || self.cachedRepository !== repository
                || self.cachedSubscriptions != subscriptions {
                self.recorder.endListening()
                self.cachedContext = self.resolve(itemId, repository)
                self.cachedItemId = itemId
                self.cachedRepository = repository
                self.cachedSubscriptions = subscriptions
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
    }
}
