import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// The files that go with an item when it is deleted for good.
extension Gate1AppModel {
    /// Runs `delete`, the call that removes the items' rows, and then removes the friend's imported packet folders
    /// those rows named, off the main thread (#3406, owner 2026-11-05: "Yes, right away."). The rule and the order
    /// are in `FriendPacketFolders`. If the delete throws, no file is touched.
    func deletingFriendRecordings(ofItems itemIds: [String], store: SQLiteSessionStore, delete: () throws -> Void) throws {
        guard let supportDirectory = try? applicationSupportDirectory() else { return try delete() }
        try FriendPacketFolders.deleting(
            itemIds: itemIds, store: store,
            directory: supportDirectory.appending(path: "SpokenMargins/IncomingPackages", directoryHint: .isDirectory),
            keeping: packageImport.foldersInUse,
            // The leveled copy of a friend's voice is found by the file's content, so it goes before the file does.
            beforeRemovingFile: { [leveledMargins = Self.leveledMargins] in leveledMargins.removeCopies(of: $0) },
            delete: delete)
    }

    /// The prepared narration file goes off the main thread (#2510), like the recordings and the episode-map folder,
    /// so a permanent delete does not wait on the unlink. The path is checked here, where the support directory
    /// is known; only the removal runs in the background.
    func removeDurableGeneratedAudio(for item: some LibraryItemFields) {
        // A friend's written Margins were read aloud from files rendered for this item (#3365). Their words go with it. All
        // the logic, and the off-main-thread removal, is the reader's; trash leaves them, so Undo still plays.
        WrittenMarginReader.shared.removeReadings(forItem: item.id, leveled: Self.leveledMargins)
        guard item.media?.sourceType == .generatedTTSPrerendered,
              let identifier = item.media?.nativeMediaId ?? item.media?.url,
              let url = URL(string: identifier),
              url.isFileURL,
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let generatedDirectory = supportDirectory
            .appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            .standardizedFileURL
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent() == generatedDirectory else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: file) }
    }

    /// The journal and the folders a permanent delete finishes removing from, even after a quit (#4227). Nil when the
    /// app's support directory can't be found; permanent delete then goes on as it did, with the files left.
    ///
    /// The Margin recordings (#1035, #2507) are found by the audio paths the deleted rows named. The rule is
    /// `MarginRecordingCleanup`'s: only a file under `SpokenMargins/`, where the recorder keeps them, and only once no
    /// Margin that stays names it. `store` is read for that on the removal step's background task, never on the main
    /// thread. The leveled playback copies (#467) are the same voice and are found by the recording's content, so they
    /// go before the recording does. If the Margins that stay can't be read, nothing is removed and the record is kept.
    private func permanentDeletePurge(store: SQLiteSessionStore) -> PermanentDeletePurge? {
        guard let support = try? applicationSupportDirectory() else { return nil }
        let leveledMargins = Self.leveledMargins
        return PermanentDeletePurge(
            journalDirectory: support.appending(path: "SpokenMargins/PurgeJournal", directoryHint: .isDirectory),
            roots: [
                .init(name: ItemOwnedFiles.preparedAudioRoot,
                      url: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.listeningEditionsRoot,
                      url: support.appending(path: "SpokenMargins/ListeningEditions", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.sourceDocumentsRoot,
                      url: support.appending(path: "SourceDocuments", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.audiobooksRoot,
                      url: support.appending(path: "Audiobooks", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.episodeMapsRoot,
                      url: support.appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.itemOriginalsRoot,
                      url: support.appending(path: "ItemOriginals", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.pdfClipsRoot, url: Self.pdfClipStore(support: support).directory),
            ],
            marginRecordings: .init(
                directory: support.appending(path: "SpokenMargins", directoryHint: .isDirectory),
                resolve: { Self.resolvedInterjectionAudioURL(for: $0, applicationSupportDirectory: support) },
                survivingAudioPaths: { try store.allMarginAudioPaths() },
                beforeRemoving: { leveledMargins.removeCopies(of: $0) }))
    }

    /// Runs `delete`, the call that removes the items' rows, and then removes the files only those items owned (their
    /// prepared narration chunks, saved Listening Edition, episode-map folder, PDF clip pictures, and the EPUB or audiobook the app copied in
    /// from Files, and the spoken Margin recordings, named by `recordingPaths`: the audio paths of the Margins the delete
    /// takes away, read with the Margins before it, quarantined ones included) off the main thread. The copied files are
    /// named by the items' ledger rows (`ledgerRows`), which the caller reads before it removes anything, next to the Margin reads, because the rows go with the items
    /// (`ItemOwnedFiles.copiedSourceTarget` keeps only the file the importer writes for the item). A read that fails
    /// stops the delete there, before any file has been touched. A record of the files is written
    /// first, so a quit or a failed removal is finished at the next launch. If `delete` throws, no file is touched.
    ///
    /// Just before each file goes, on that background task, the Library is asked again whether the file is still free: an
    /// item imported again under the same id keeps its Edition, and a prepared-narration folder that another item's id
    /// maps to keeps its chunks (`ItemOwnedFiles.stillFree`). The store is read there, never on the main thread.
    func purgingItemFiles(
        ofItems itemIds: [String], ledgerRows: [OwnedOfflineAsset], recordingPaths: [String],
        store: SQLiteSessionStore, delete: () throws -> Void
    ) throws {
        guard let purge = permanentDeletePurge(store: store) else { return try delete() }
        try purge.deleting(
            itemIds: itemIds, targets: ItemOwnedFiles.targets(forItems: itemIds, assets: ledgerRows),
            recordingPaths: recordingPaths, recheck: purge.storeRecheck(store: store), delete: delete)
    }

    /// Finishes what a permanent delete left when the app was quit part way. Reads the Library off the main thread
    /// and does nothing when no delete was interrupted.
    func finishInterruptedPermanentDeletes(store: SQLiteSessionStore) {
        guard let purge = permanentDeletePurge(store: store) else { return }
        // A record written after this moment is a delete running in this process, which finishes it itself.
        let launchBegan = Date()
        Task.detached(priority: .utility) { [weak self] in
            let outcome = purge.resumePending(recordsBefore: launchBegan, store: store)
            // Whatever the journal had to do, a queued id with no item behind it goes (#4227). A read that fails keeps the queue.
            if let storedIds = try? store.loadAllItemIds() {
                let stored = Set(storedIds)
                await MainActor.run { self?.pruneQueueOfDeletedItems(storedIds: stored) }
            }
            guard outcome.removed.count + outcome.kept.count + outcome.abandonedRecords
                + outcome.recordingsDone + outcome.recordingsKept > 0 else { return }
            let line = "removed:\(outcome.removed.count):kept:\(outcome.kept.count):abandoned:\(outcome.abandonedRecords)"
                + ":recordings:\(outcome.recordingsDone):recordingsKept:\(outcome.recordingsKept)"
            await MainActor.run { self?.diagnostics["lastPermanentDeleteResume"] = line }
        }
    }
}
