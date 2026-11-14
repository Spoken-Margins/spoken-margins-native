import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// The files that go with an item when it is deleted for good.
extension Gate1AppModel {
    /// Removes the spoken Margin recordings of Margins whose rows were just deleted (#1035). The rows were
    /// read before the delete; `store` now holds only the Margins that stay. If every audio path those name
    /// can't be read (a row that no longer decodes still counts), nothing is removed: a recording is only
    /// deleted once no remaining Margin is known to use it. Only files under `SpokenMargins/`, where the
    /// recorder keeps them, are ever removed.
    ///
    /// `quarantinedAudioPaths` are the recordings of the item's Margins that were set aside because they
    /// couldn't be decoded (`SQLiteSessionStore.quarantinedMarginAudioPaths`, read before the delete, #1466).
    ///
    /// The surviving-paths scan and the file removals run on `StoreReader`'s background task (#2507, #2510), so
    /// permanent delete no longer waits on them. A recording whose removal is still pending when the app is killed
    /// stays on disk, as one whose removal failed always did.
    func removeMarginRecordings(_ deleted: [Interjection], quarantinedAudioPaths: [String] = [], store: SQLiteSessionStore) {
        let deletedAudioPaths = deleted.compactMap(\.audioPath) + quarantinedAudioPaths
        guard !deletedAudioPaths.isEmpty,
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let recordings = supportDirectory.appending(path: "SpokenMargins", directoryHint: .isDirectory)
        let resolve: @Sendable (String) -> URL? = {
            Self.resolvedInterjectionAudioURL(for: $0, applicationSupportDirectory: supportDirectory)
        }
        let leveledMargins = Self.leveledMargins
        Task {
            await MarginRecordingRemoval.removeUnreferenced(
                deletedAudioPaths: deletedAudioPaths, store: store, within: recordings, resolve: resolve,
                // The leveled playback copies (#467) are the same voice. They are found by the recording's
                // content, so they go before the recording does.
                beforeRemoving: { leveledMargins.removeCopies(of: $0) }
            )
        }
    }

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
    private func permanentDeletePurge() -> PermanentDeletePurge? {
        guard let support = try? applicationSupportDirectory() else { return nil }
        return PermanentDeletePurge(
            journalDirectory: support.appending(path: "SpokenMargins/PurgeJournal", directoryHint: .isDirectory),
            roots: [
                .init(name: ItemOwnedFiles.preparedAudioRoot,
                      url: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)),
                .init(name: ItemOwnedFiles.listeningEditionsRoot,
                      url: support.appending(path: "SpokenMargins/ListeningEditions", directoryHint: .isDirectory)),
            ])
    }

    /// Runs `delete`, the call that removes the items' rows, and then removes the files only those items owned (their
    /// prepared narration chunks and saved Listening Edition) off the main thread. A record of the files is written
    /// first, so a quit or a failed removal is finished at the next launch. If `delete` throws, no file is touched.
    ///
    /// A prepared-narration folder is named only when no other item's row maps to the same folder name, so `store` is read
    /// for the ids. If that read fails, the folder is left (re-rendered narration at worst) and the Edition still goes.
    func purgingItemFiles(ofItems itemIds: [String], store: SQLiteSessionStore, delete: () throws -> Void) throws {
        guard let purge = permanentDeletePurge() else { return try delete() }
        let existing = try? store.loadAllItemIds()
        let targets = existing.map { ItemOwnedFiles.targets(forItems: itemIds, existingItemIds: $0) }
            ?? ItemOwnedFiles.targets(forItems: itemIds, existingItemIds: [], namingPreparedAudio: false)
        try purge.deleting(itemIds: itemIds, targets: targets, delete: delete)
    }

    /// Finishes what a permanent delete left when the app was quit part way. Reads the Library off the main thread
    /// and does nothing when no delete was interrupted.
    func finishInterruptedPermanentDeletes(store: SQLiteSessionStore) {
        guard let purge = permanentDeletePurge() else { return }
        // A record written after this moment is a delete running in this process, which finishes it itself.
        let launchBegan = Date()
        Task.detached(priority: .utility) { [weak self] in
            let outcome = purge.resumePending(recordsBefore: launchBegan, store: store)
            guard outcome.removed.count + outcome.kept.count + outcome.abandonedRecords > 0 else { return }
            let line = "removed:\(outcome.removed.count):kept:\(outcome.kept.count):abandoned:\(outcome.abandonedRecords)"
            await MainActor.run { self?.diagnostics["lastPermanentDeleteResume"] = line }
        }
    }
}
