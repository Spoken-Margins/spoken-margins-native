import AVFoundation
import Foundation
import SessionKit

extension ListeningSignalRecorder {
    /// The app's I4 log in Application Support (#483). Private to the device; only the owner's
    /// explicit export in Settings ever copies it anywhere.
    static let app = ListeningSignalRecorder(
        fileURL: ListeningSignalRecorder.defaultFileURL(
            applicationSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
    )
}

/// Turns app actions on Library items into I4 rows (#483). Each call site in `Gate1AppModel` is
/// one line; this type finds the followed source and feed entry behind an item id and hands the
/// row to the recorder, which buffers and writes off the main thread. Items that don't come from
/// a followed source are not logged.
@MainActor
final class ListeningSignalsCoordinator {
    private let recorder: ListeningSignalRecorder
    private let repository: @MainActor () -> (any SessionRepository)?
    /// The playing item's context, so progress ticks don't query the store.
    private var cachedItemId: String?
    private var cachedContext: (source: ListeningSignalSource, item: ListeningSignalItem)?

    init(recorder: ListeningSignalRecorder = .app, repository: @escaping @MainActor () -> (any SessionRepository)?) {
        self.recorder = recorder
        self.repository = repository
    }

    /// One playback progress tick. The recorder coalesces ticks into intervals.
    func listened(itemId: String?) {
        guard let itemId else { return }
        if cachedItemId != itemId {
            let resolved = context(forItemId: itemId)
            cachedItemId = itemId
            cachedContext = resolved
        }
        guard let context = cachedContext else { return }
        recorder.noteListening(source: context.source, item: context.item)
    }

    /// Playback stopped: close the open interval, and look the item up again next time (it may
    /// have been followed or re-imported meanwhile).
    func endListening() {
        recorder.endListening()
        cachedItemId = nil
        cachedContext = nil
    }

    func writtenMargin(itemId: String?, text: String) {
        record(.margin(kind: .written, length: text.count), itemId: itemId)
    }

    /// Spoken Margin length is its recording's duration, read off the main thread.
    func spokenMargin(itemId: String?, audioURL: URL?) {
        guard let itemId, let context = context(forItemId: itemId) else { return }
        let source = context.source, item = context.item, at = Date(), signals = self.recorder
        Task.detached(priority: .utility) {
            var seconds = 0
            if let audioURL, let duration = try? await AVURLAsset(url: audioURL).load(.duration), duration.isNumeric {
                seconds = max(0, Int(duration.seconds.rounded()))
            }
            signals.record(.margin(kind: .spoken, length: seconds), source: source, item: item, at: at)
        }
    }

    func share(itemId: String?) {
        record(.share, itemId: itemId)
    }

    func export(itemId: String?, packetId: String, marginCount: Int) {
        record(.export(packetId: packetId, marginCount: marginCount), itemId: itemId)
    }

    func packetImport(itemId: String?, packetId: String, marginCount: Int) {
        guard let itemId, let context = context(forItemId: itemId) else { return }
        recorder.recordPacketImport(packetId: packetId, marginCount: marginCount, source: context.source, item: context.item)
    }

    func finish(itemId: String?) {
        record(.finish, itemId: itemId)
    }

    func dismiss(entryId: String) {
        guard let repository = repository(),
              let context = ListeningSignalContext.context(
                forEntryId: entryId,
                entries: (try? repository.loadFeedEntries(subscriptionId: nil)) ?? [],
                subscriptions: (try? repository.loadFeedSubscriptions()) ?? [],
                seenAt: Date()
              ) else { return }
        recorder.record(.dismiss, source: context.source, item: context.item)
    }

    /// A copy of the log for the share sheet, or nil when nothing has been logged yet.
    func exportFileURL() -> URL? {
        try? recorder.exportCopy(to: FileManager.default.temporaryDirectory.appendingPathComponent("ListeningSignals", isDirectory: true))
    }

    private func record(_ event: ListeningSignalEvent, itemId: String?) {
        guard let itemId, let context = context(forItemId: itemId) else { return }
        recorder.record(event, source: context.source, item: context.item)
    }

    private func context(forItemId itemId: String) -> (source: ListeningSignalSource, item: ListeningSignalItem)? {
        if itemId == cachedItemId { return cachedContext }
        guard let repository = repository(),
              let item = try? repository.loadItem(id: itemId),
              let subscriptions = try? repository.loadFeedSubscriptions(),
              !subscriptions.isEmpty else { return nil }
        let entries = (try? repository.loadFeedEntries(subscriptionId: nil)) ?? []
        return ListeningSignalContext.context(for: item, subscriptions: subscriptions, entries: entries)
    }
}
