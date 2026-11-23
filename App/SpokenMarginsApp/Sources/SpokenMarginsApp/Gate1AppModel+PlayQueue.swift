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
        PlayQueueState.shared.itemIds = loaded.itemIds
        return loaded
    }

    static func update(_ model: Gate1AppModel, _ change: (inout PlayQueue) -> Void) {
        var value = current(model)
        change(&value)
        queue = value
        PlayQueueState.shared.itemIds = value.itemIds
        do { try store(model)?.save(value) } catch { model.diagnostics["playQueueSave"] = "failed: \(SafeErrorText.describe(error))" }
    }

    /// Takes deleted items out of the queue and its file, so one imported again under the same id (a packet's id is
    /// deterministic) does not come back into a queue it had been deleted from (#4227). Writes nothing when none is queued.
    static func forget(_ model: Gate1AppModel, itemIds: [String]) {
        let queued = current(model)
        guard itemIds.contains(where: { queued.contains($0) }) else { return }
        update(model) { $0.removeAll(in: itemIds) }
    }

    private static func store(_ model: Gate1AppModel) -> PlayQueueStore? {
        guard let directory = try? model.applicationSupportDirectory() else { return nil }
        return PlayQueueStore(fileURL: directory.appending(path: "play-queue.json"))
    }
}

/// The queue's ids as views watch them (#1990), so the Library entry and the queue screen follow every change without a
/// flag on `Gate1AppModel`. `PlayQueueController` is the only writer.
@MainActor
final class PlayQueueState: ObservableObject {
    static let shared = PlayQueueState()
    @Published fileprivate(set) var itemIds: [String] = []
}

extension Gate1AppModel {
    /// Loads the queue file once, so the Library can show its entry at launch.
    func loadPlayQueue() { _ = PlayQueueController.current(self) }

    /// Plays a queued item now, from the queue screen. It leaves the queue once it has started, as it does when it
    /// starts by advancing. A start that was refused (recording a Margin, an episode not downloaded while offline) keeps
    /// its place in the queue.
    func playQueuedItemNow(itemId: String) {
        startItem(id: itemId)
        guard snapshot.itemId == itemId else { return }
        PlayQueueController.update(self) { $0.remove(itemId) }
    }

    /// The queued item the chapter row's "Next in queue" starts, or nil where it isn't offered (#3914). Not while a Skim
    /// summary plays: the slot is dimmed then even with a chapter ahead, and it must not turn into Next in queue
    /// on an earlier chapter. Not once the item has finished either: the queue is advancing by itself then. It has already
    /// taken the next item off the queue and starts it a moment later, and a tap in that gap would start the item
    /// after it and lose it when the advance's own start replaced it.
    var chapterRowQueuedNextId: String? {
        guard snapshot.skimBridgeState == nil, snapshot.phase != .finished else { return nil }
        return PlayQueueController.current(self).nextToStart(
            playing: snapshot.itemId, starting: activeItemId, isAvailable: { id in libraryItems.contains { $0.id == id } })
    }

    /// Starts the item "Next in queue" was drawn for, through the queue screen's own path (#3914): the item's own place,
    /// the sleep timer cancelled, the old session ended as for any new start (so it keeps its place and isn't finished),
    /// and the item leaving the queue once it has started. `expectedId` is the item the button showed; if the queue has
    /// moved on since (a second tap, or the queue advancing by itself at the end), nothing starts.
    func playNextQueuedItem(expectedId: String) {
        guard chapterRowQueuedNextId == expectedId else { return }
        playQueuedItemNow(itemId: expectedId)
    }

    func removeFromQueue(itemId: String) {
        PlayQueueController.update(self) { $0.remove(itemId) }
    }

    func moveInQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        let available = Set(libraryItems.map(\.id))
        PlayQueueController.update(self) {
            $0.prune(isAvailable: { available.contains($0) }) // the rows on screen are the queue, with no hidden items
            $0.move(fromOffsets: source, toOffset: destination)
        }
    }

    /// Permanent delete takes the items' ids out of the play queue's file (#4227); until now the file kept them until the
    /// next reorder or advance.
    func removeFromQueue(deletedItemIds ids: [String]) {
        PlayQueueController.forget(self, itemIds: ids)
    }

    /// At launch, after the interrupted deletes are finished: queued ids that belong to no item are taken out. A delete
    /// that was killed after the rows went and before `removeFromQueue(deletedItemIds:)` ran leaves such ids. The store is
    /// read by the caller, off the main thread; here, on the main actor, an id the app's own lists hold is never taken
    /// out, so an item added while the read ran keeps its place.
    func pruneQueueOfDeletedItems(storedIds: Set<String>) {
        let known = Set(libraryItems.map(\.id)).union(recentlyDeletedItems.map(\.id))
        let orphans = PlayQueueOrphans.orphans(in: PlayQueueController.current(self), storedIds: storedIds, knownNow: known)
        guard !orphans.isEmpty else { return }
        PlayQueueController.forget(self, itemIds: orphans)
    }

    func clearPlayQueue() {
        PlayQueueController.update(self) { $0.clear() }
    }

    func queuePlayNext(itemId: String) {
        PlayQueueController.update(self) { $0.playNext(itemId) }
        reportSuccess("\(queuedTitle(itemId)) plays next.")
    }

    func queueAppend(itemId: String) {
        PlayQueueController.update(self) { $0.append(itemId) }
        reportSuccess(QueueRowAction.add.banner(title: queuedTitle(itemId)))
    }

    func queuedTitle(_ itemId: String) -> String {
        libraryItems.first(where: { $0.id == itemId })?.title ?? "Untitled"
    }

    /// Starts the next queued item when the one that was playing reaches its end. Not while a sleep timer is running:
    /// the listener asked for the audio to stop, and a queued item would play on past it.
    func playQueueSnapshotChanged(from previous: SessionSnapshot, to current: SessionSnapshot) {
        guard PlayQueueAdvance.shouldAdvance(from: previous, to: current), !sleepTimerIsActive else { return }
        let available = Set(libraryItems.map(\.id))
        var next: String?
        PlayQueueController.update(self) { next = $0.popNext(isAvailable: { available.contains($0) }) }
        guard let next else { return }
        // After this snapshot change has settled: starting a session writes the snapshot again. The queue moved on
        // by itself, so no new publisher page is read for it (#4640, the 2026-10-21 rule).
        Task { @MainActor [weak self] in
            guard let self else { return }
            hangTelemetry.labels.scoped("playQueueAdvance") { startItem(id: next, trigger: .queueAdvance) }
        }
    }
}

/// The Quick Folder as an inbox (#1990 slice 3): with the setting on, files that newly appear in the folder are imported
/// through the same Quick Folder import and appended to the play queue in filename order. It runs after each folder
/// refresh, including the one at launch, so a file added while the app was closed is queued the next time it opens.
extension Gate1AppModel {
    func quickFolderInboxRefreshed() {
        guard quickAccess.inboxFeedsQueue, !quickAccess.isRefreshing else { return }
        // The whole folder, not the Quick Add list's eight: a batch of more than eight new files arrives in passes (#3767).
        // A link list that waited offline or failed while online is held out until the app next comes forward (#4683).
        let plan = QuickFolderInbox.plan(
            files: quickAccess.inboxFiles.filter { !linkListArrival.isHeld($0.id) },
            seenKeys: quickAccess.inboxSeenFileIds,
            dismissedKeys: quickAccess.dismissedFileKeys,
            seenCoversWholeFolder: quickAccess.inboxSeenCoversWholeFolder
        )
        if !plan.grandfatheredKeys.isEmpty {
            quickAccess.inboxSeenFileIds = (quickAccess.inboxSeenFileIds ?? []).union(plan.grandfatheredKeys)
        }
        // A baseline taken now covers the folder, and so does a plan that saw files. An empty listing against an existing
        // seen set may be a folder still syncing, which proves nothing about which files were already there.
        if !quickAccess.inboxFiles.isEmpty || quickAccess.inboxSeenFileIds == nil {
            quickAccess.inboxSeenCoversWholeFolder = true
        }
        guard !plan.toImport.isEmpty else {
            if quickAccess.inboxSeenFileIds == nil { quickAccess.inboxSeenFileIds = plan.newSeenKeys }
            return
        }
        // One import at a time; the next refresh picks these up again because they are not marked seen yet.
        guard !linkListArrivalIsBusy, let folderURL = quickAccess.resolvedFolderURL() else { return }
        // Link lists (#3767) go first and alone: they arrive as a collection or loose items, in file order, and their
        // follow entries wait as suggestions (#4683). The files that are not marked seen yet are picked up by the refresh
        // that import ends with, so text files follow right after. A list that waited offline or failed while online is
        // taken out of the seen set again and tried at the next refresh once the app comes forward, up to three tries.
        let linkLists = plan.toImport.filter(Self.isQuickFolderLinkList)
        if !linkLists.isEmpty {
            quickAccess.inboxSeenFileIds = (quickAccess.inboxSeenFileIds ?? []).union(linkLists.map(\.id))
            importQuickFolderLinkLists(linkLists, folderURL: folderURL, automatic: true)
            return
        }
        quickAccess.inboxSeenFileIds = (quickAccess.inboxSeenFileIds ?? []).union(plan.newSeenKeys)
        let files = plan.toImport
        // A `.txt` that reads as a meeting transcript is saved as a transcript item and queued like any other (#2997).
        importFilesWithTranscriptRule(
            urls: files.map { folderURL.appending(path: $0.relativePath) },
            route: quickFolderInboxRoute(files: files, folderURL: folderURL))
    }

    /// How the inbox imports its new files: no navigation, "Queued N new Quick Folder files." for text files, and every
    /// item the pick saved appended to the queue in the order of `files`, with the files dismissed. A failed file was
    /// already reported by the import.
    func quickFolderInboxRoute(files: [QuickAccessFile], folderURL: URL) -> TranscriptPickRoute {
        TranscriptPickRoute(
            securityScopedURLs: [folderURL],
            refreshQuickFolderWhenFinished: true,
            navigatesWhenFinished: false,
            confirmationOverride: { "Queued \($0) new Quick Folder file\($0 == 1 ? "" : "s")." },
            onFinished: { [weak self] outcome in
                guard let self, !outcome.itemIds.isEmpty else { return }
                PlayQueueController.update(self) { queue in outcome.itemIds.forEach { queue.append($0) } }
                files.forEach { self.dismissQuickAccessFile($0) }
                self.diagnostics["quickFolderInboxQueued"] = "\(outcome.itemIds.count)"
            })
    }
}
