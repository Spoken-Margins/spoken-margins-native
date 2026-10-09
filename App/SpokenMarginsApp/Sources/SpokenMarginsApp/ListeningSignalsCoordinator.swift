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
    private let collector: ListeningSignalCollector
    private let repository: @MainActor () -> (any SessionRepository)?
    private var pendingDurations: [UUID: Task<Void, Never>] = [:]
    /// Spoken Margins already counted: a finish that saved and then failed to resume reaches the hook twice.
    /// Margin ids are only unique within a session (`ij-001`), so the session id is part of the key.
    private var countedSpokenMargins: Set<[String]> = []
    /// The item each packet file was built for, so a share sheet that completes later credits that
    /// item even if the selection has moved on meanwhile.
    private var exportedItems: [URL: String] = [:]
    private var finishes = ListeningSignalFinishTracker()
    init(recorder: ListeningSignalRecorder = .app, repository: @escaping @MainActor () -> (any SessionRepository)?) {
        self.collector = ListeningSignalCollector(recorder: recorder)
        self.repository = repository
    }

    /// The tick path captures values and enqueues; all context reads happen on the collector's queue.
    func playbackProgress(itemId: String?, status: PlaybackStatus, transport: PlaybackTransportState? = nil) {
        collector.playbackProgress(itemId: itemId, status: status, transport: transport, repository: repository())
    }

    func endListening() {
        collector.endListening()
    }

    func writtenMargin(itemId: String?, text: String) {
        record(.margin(kind: .written, length: text.count), itemId: itemId)
    }

    /// Spoken Margin length is its recording's duration, read off the main thread.
    func spokenMargin(sessionId: String, interjectionId: String, itemId: String?, audioURL: URL?) {
        guard countedSpokenMargins.insert([sessionId, interjectionId]).inserted else { return }
        let store = repository(), at = Date(), signals = collector
        let id = UUID()
        let task = Task.detached(priority: .utility) {
            var seconds = 0
            if let audioURL, let duration = try? await AVURLAsset(url: audioURL).load(.duration), duration.isNumeric {
                seconds = max(0, Int(duration.seconds.rounded()))
            }
            signals.record(.margin(kind: .spoken, length: seconds), itemId: itemId, repository: store, at: at)
        }
        pendingDurations[id] = task
        Task { [weak self] in
            await task.value
            self?.pendingDurations.removeValue(forKey: id)
        }
    }

    /// The system share sheet sent `packetURL`; the row goes to the item the packet was built for.
    func share(packetURL: URL) {
        record(.share, itemId: exportedItems[packetURL.standardizedFileURL])
    }

    func export(itemId: String?, packetId: String, marginCount: Int, packetURL: URL) {
        exportedItems[packetURL.standardizedFileURL] = itemId
        record(.export(packetId: packetId, marginCount: marginCount), itemId: itemId)
    }

    func packetImport(itemId: String?, packetId: String, marginCount: Int) {
        collector.packetImport(itemId: itemId, packetId: packetId, marginCount: marginCount, repository: repository())
    }

    func finish(itemId: String?) {
        record(.finish, itemId: itemId)
    }

    /// Every snapshot change: a session moving into finished records `finish`, whether playback
    /// reached the end or a transport command skipped past it.
    func snapshotChanged(from previous: SessionSnapshot, to current: SessionSnapshot) {
        if let itemId = finishes.finishedItem(from: previous, to: current) { finish(itemId: itemId) }
    }

    func dismiss(entryId: String) {
        collector.dismiss(entryId: entryId, repository: repository())
    }

    /// A followed article keeps the page's final URL as its identity; remember the entry it came
    /// from, so its rows join that entry after a redirect or when two feeds list it. Returns the handoff unchanged.
    func followedArticle(_ handoff: BrowserTextHandoff, for entry: FeedEntry) -> BrowserTextHandoff {
        collector.importedEntries.note(handoff, for: entry)
    }

    /// The Library item a followed article was imported as, so its rows keep this entry even if a
    /// later edition of the same article is imported from another feed (#865). Returns `itemId`.
    @discardableResult
    func followedArticleImported(_ itemId: String, for entry: FeedEntry) -> String {
        collector.importedEntries.note(itemId: itemId, for: entry)
        return itemId
    }

    /// A copy of the log for the share sheet, or nil when nothing has been logged yet.
    func exportFileURL() async -> URL? {
        // Capture the work already present at invocation. Later actions do not keep this
        // export waiting indefinitely; every captured task enqueues before the queue drains.
        let pending = Array(pendingDurations.values)
        for task in pending { await task.value }
        let signals = collector
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ListeningSignals", isDirectory: true)
        return await Task.detached(priority: .utility) {
            try? signals.exportCopy(to: directory)
        }.value
    }

    private func record(_ event: ListeningSignalEvent, itemId: String?) {
        collector.record(event, itemId: itemId, repository: repository())
    }
}
