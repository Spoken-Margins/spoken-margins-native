import Foundation
import SessionKit

/// The listener's play queue (#1990): "Play Next" and "Add to Queue" in the item menu, and the next queued item starting
/// when the one playing finishes. The queue is one small file in Application Support, so the database is unchanged and the
/// last shipped build opens it as before.
@MainActor
enum PlayQueueController {
    private(set) static var queue: PlayQueue?

    static func current(_ model: Gate1AppModel) -> PlayQueue {
        if let queue { return queue }
        let loaded = store(model)?.load() ?? PlayQueue()
        queue = loaded
        return loaded
    }

    static func update(_ model: Gate1AppModel, _ change: (inout PlayQueue) -> Void) {
        var value = current(model)
        change(&value)
        queue = value
        do { try store(model)?.save(value) } catch { model.diagnostics["playQueueSave"] = "failed: \(error.localizedDescription)" }
    }

    private static func store(_ model: Gate1AppModel) -> PlayQueueStore? {
        guard let directory = try? model.applicationSupportDirectory() else { return nil }
        return PlayQueueStore(fileURL: directory.appending(path: "play-queue.json"))
    }
}

extension Gate1AppModel {
    func queuePlayNext(itemId: String) {
        PlayQueueController.update(self) { $0.playNext(itemId) }
        reportSuccess("\(queuedTitle(itemId)) plays next.")
    }

    func queueAppend(itemId: String) {
        PlayQueueController.update(self) { $0.append(itemId) }
        reportSuccess("Added \(queuedTitle(itemId)) to the queue.")
    }

    private func queuedTitle(_ itemId: String) -> String {
        libraryItems.first(where: { $0.id == itemId })?.title ?? "Item"
    }

    /// Starts the next queued item when the one that was playing reaches its end. Not while a sleep timer is running:
    /// the listener asked for the audio to stop, and a queued item would play on past it.
    func playQueueSnapshotChanged(from previous: SessionSnapshot, to current: SessionSnapshot) {
        guard PlayQueueAdvance.shouldAdvance(from: previous, to: current), !sleepTimerIsActive else { return }
        let available = Set(libraryItems.map(\.id))
        var next: String?
        PlayQueueController.update(self) { next = $0.popNext(isAvailable: { available.contains($0) }) }
        guard let next else { return }
        // After this snapshot change has settled: starting a session writes the snapshot again.
        Task { @MainActor [weak self] in
            guard let self else { return }
            hangTelemetry.labels.scoped("playQueueAdvance") { startItem(id: next) }
        }
    }
}

/// The Quick Folder as an inbox (#1990 slice 3): with the setting on, files that newly appear in the folder are imported
/// through the same Quick Folder import and appended to the play queue in filename order. It runs after each folder
/// refresh, including the one at launch, so a file added while the app was closed is queued the next time it opens.
extension Gate1AppModel {
    func quickFolderInboxRefreshed() {
        guard quickAccess.inboxFeedsQueue, !quickAccess.isRefreshing else { return }
        let plan = QuickFolderInbox.plan(
            files: quickAccess.recentFiles,
            seenKeys: quickAccess.inboxSeenFileIds,
            dismissedKeys: quickAccess.dismissedFileKeys
        )
        guard !plan.toImport.isEmpty else {
            if quickAccess.inboxSeenFileIds == nil { quickAccess.inboxSeenFileIds = plan.newSeenKeys }
            return
        }
        // One import at a time; the next refresh picks these up again because they are not marked seen yet.
        guard sourceImportTask == nil, let folderURL = quickAccess.resolvedFolderURL() else { return }
        quickAccess.inboxSeenFileIds = (quickAccess.inboxSeenFileIds ?? []).union(plan.newSeenKeys)
        let files = plan.toImport
        beginObsidianMarkdownImport(
            urls: files.map { folderURL.appending(path: $0.relativePath) },
            securityScopedURLs: [folderURL],
            refreshQuickFolderWhenFinished: true,
            onImported: { [weak self] items in
                guard let self else { return }
                // Imported items keep the order of `files`. A failed file was already reported by the import.
                PlayQueueController.update(self) { queue in items.forEach { queue.append($0.id) } }
                files.forEach { self.dismissQuickAccessFile($0) }
                self.diagnostics["quickFolderInboxQueued"] = "\(items.count)"
            }
        )
    }
}
