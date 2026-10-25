import Foundation
import SessionKit
import SessionKitPersistence

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    @discardableResult
    func importListeningEditionData(_ data: Data, replaceMap: Bool = false) -> Bool {
        do {
            try performListeningEditionImport(data, replaceMap: replaceMap)
            return true
        } catch {
            reportFailure(error, context: "Listening edition import failed")
            return false
        }
    }

    /// One already-decoded edition from the Listening Edition screen. Opens the item, as a single file always has.
    @discardableResult
    func importListeningEdition(_ edition: ListeningEdition, replaceMap: Bool = false) -> Bool {
        do {
            try openAfterImporting(edition, replaceMap: replaceMap)
            return true
        } catch {
            reportFailure(error, context: "Listening edition import failed")
            return false
        }
    }

    /// Several editions at once (#1472): saves each one and leaves the listener where they are. It opens no item
    /// and starts no playback, and a source that already has a different map keeps it (replacing that stays
    /// on the single-file path, with its toggle). One result line per entry.
    func importListeningEditions(_ entries: [ListeningEditionBatch.Entry]) -> [ListeningEditionBatch.Line] {
        defer {
            if let store, let rows = try? loadLibraryRows(store: store) { libraryItems = rows }
            refreshSelectedItem()
        }
        return ListeningEditionBatch.run(entries, existing: { edition in
            guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
            guard let previous = try ListeningEditionStore.application().load(itemID: edition.itemID) else { return .none }
            if previous != edition { return .different }
            // Saved edition but the item is gone from the Library: import it again.
            return (try? requireStore().loadItem(id: edition.itemID)) == nil ? .none : .identical
        }, importOne: { edition in
            try saveListeningEdition(edition, replaceMap: false)
            scheduleTextAudioPrewarmIfNeeded(itemId: edition.itemID)
        })
    }

    /// Collection files picked from the Add sheet's Files route (#2373). Like a PDF added there, they land in the
    /// Library and nothing opens or plays. Returns whether every file went in, so the sheet knows to close.
    @discardableResult
    func importListeningEditionFiles(_ urls: [URL], folders: [URL] = []) async -> Bool {
        // The folders are walked and the files read and decoded off the main thread (#2510, #2256); the import
        // itself still runs on it.
        let loaded = await Task.detached(priority: .userInitiated) { Self.readListeningEditionEntries(urls, folders: folders) }.value
        if loaded.entries.isEmpty {
            reportFailure(ListeningEditionFolderWalk.emptyMessage(folderNames: folders.map(\.lastPathComponent)))
            return false
        }
        let lines = hangTelemetry.labels.scoped("listeningEditionFiles.import") { importListeningEditions(loaded.entries) }
        var summary = ListeningEditionBatch.summary(of: lines)
        if loaded.truncated {
            summary = summary.appending(ListeningEditionFolderWalk.truncationNote())
        }
        if lines.contains(where: { $0.outcome.isSuccess }) { markOnboardingSteps([.addedOwnSource, .addedFromFiles]) }
        if summary.isFailure {
            reportFailure(summary.message)
        } else {
            reportConfirmation(summary.message)
        }
        return !summary.isFailure
    }

    /// Reads the picked files, plus the `.json` files found in the picked folders (#2672), into batch entries.
    /// A folder's security-scoped access stays open while its files are read, since the files inherit it.
    private nonisolated static func readListeningEditionEntries(_ urls: [URL], folders: [URL])
        -> (entries: [ListeningEditionBatch.Entry], truncated: Bool) {
        var all = urls
        var truncated = false
        var scoped: [URL] = []
        defer { for folder in scoped { folder.stopAccessingSecurityScopedResource() } }
        for folder in folders {
            if folder.startAccessingSecurityScopedResource() { scoped.append(folder) }
            let room = max(0, ListeningEditionFolderWalk.defaultMaxFiles - (all.count - urls.count))
            let walked = ListeningEditionFolderWalk.collect(in: folder, maxFiles: room)
            all.append(contentsOf: walked.urls)
            if walked.truncated { truncated = true }
        }
        return (all.enumerated().map { ListeningEditionBatch.Entry.reading(url: $1, id: $0) }, truncated)
    }

    /// One edition file from a file open or a staged hand-off. The file is read off the main thread (#2510).
    func importListeningEditionFile(_ url: URL) {
        Task { @MainActor in
            do {
                let data = try await Self.offMain { try Self.listeningEditionFileData(url) }
                hangTelemetry.labels.scoped("listeningEditionFile.import") { importListeningEditionData(data) }
            } catch { reportFailure(error, context: "Listening edition file could not be opened") }
        }
    }

    private nonisolated static func listeningEditionFileData(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw EditionError.invalid("Listening edition exceeds 8 MB.") }
        return try Data(contentsOf: url)
    }

    func importListeningEditionDataForShortcut(_ data: Data) throws {
        try performListeningEditionImport(data, replaceMap: false)
    }

    private func performListeningEditionImport(_ data: Data, replaceMap: Bool) throws {
        guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
        try openAfterImporting(try ListeningEdition.decode(data), replaceMap: replaceMap)
    }

    private func openAfterImporting(_ edition: ListeningEdition, replaceMap: Bool) throws {
        try saveListeningEdition(edition, replaceMap: replaceMap)
        let store = try requireStore()
        activeItemId = edition.itemID
        libraryItems = try loadLibraryRows(store: store)
        refreshSelectedItem()
        screen = .item
        scheduleTextAudioPrewarmIfNeeded(itemId: edition.itemID)
        reportConfirmation("Imported item and Listening Map. Audio prepares separately; playback has not started.")
    }

    /// Saves the item, the edition and its map. Navigates nowhere.
    private func saveListeningEdition(_ edition: ListeningEdition, replaceMap: Bool) throws {
        guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
        let editions = try ListeningEditionStore.application()
        if let previous = try editions.load(itemID: edition.itemID), previous != edition, !replaceMap {
            throw EditionError.invalid("This source already has a different Listening Map. To replace it, preview this edition (Review on its own, or paste it) in Import Listening Edition and turn on Replace.")
        }
        let store = try requireStore()
        // Stable source identity preserves every existing session and Margin on retry.
        if (try? store.loadItem(id: edition.itemID)) == nil {
            try store.saveItem(Item(id: edition.itemID, title: edition.title, mediaType: "text", text: edition.text,
                                   externalReference: edition.sourceURL, status: "ready", externalReferenceType: "url", createdAt: Date()))
        }
        if snapshot.itemId == edition.itemID, snapshot.status.isPlaybackActive {
            throw EditionError.invalid("Pause playback before importing a map for the current item.")
        }
        try editions.save(edition)
        if let engine { snapshot = try engine.attachListeningMap(edition.listeningMap()) }
        else { try store.saveListeningMap(edition.listeningMap()) }
        if let timeline = try store.loadTranscriptTimeline(itemId: edition.itemID)?.timeline {
            activateListeningEditionAudio(itemId: edition.itemID, timeline: timeline)
        }
    }

    /// Saves a shared Listening Map for a text item (#1471). A running session reads its map from memory, so it is
    /// told too; the item that is playing is left alone until the listener pauses, as for an edition above.
    func attachSharedTextListeningMap(_ map: ListeningMap) throws {
        if snapshot.itemId == map.itemId, snapshot.status.isPlaybackActive {
            throw SessionKitError.persistenceFailed("shared_map_item_is_playing")
        }
        if let engine {
            snapshot = try engine.attachListeningMap(map)
        } else {
            try requireStore().saveListeningMap(map)
        }
    }

    /// A tap on a "ready to listen" notification opens that item, unless a Margin is recording.
    func openReadyListeningEdition() {
        guard !snapshot.isRecording, let id = ListeningReadyNotifications.pendingItemID else { return }
        ListeningReadyNotifications.pendingItemID = nil
        openItem(id: id)
    }
}
