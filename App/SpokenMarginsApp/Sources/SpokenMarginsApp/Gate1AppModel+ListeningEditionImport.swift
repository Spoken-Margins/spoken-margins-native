import Foundation
import SessionKit
import SessionKitPersistence

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    @discardableResult
    func importListeningEditionData(_ data: Data, replaceMap: Bool = false) async -> Bool {
        do {
            try await performListeningEditionImport(data, replaceMap: replaceMap)
            return true
        } catch {
            reportFailure(error, context: "Listening edition import failed")
            return false
        }
    }

    /// One already-decoded edition from the Listening Edition screen. Opens the item, as a single file always has.
    @discardableResult
    func importListeningEdition(_ edition: ListeningEdition, replaceMap: Bool = false) async -> Bool {
        do {
            try await openAfterImporting(edition, replaceMap: replaceMap)
            return true
        } catch {
            reportFailure(error, context: "Listening edition import failed")
            return false
        }
    }

    /// Several editions at once (#1472): saves each one and leaves the listener where they are. It opens no item
    /// and starts no playback, and a source that already has a different map keeps it (replacing that stays
    /// on the single-file path, with its toggle). One result line per entry.
    func importListeningEditions(_ entries: [ListeningEditionBatch.Entry]) async -> [ListeningEditionBatch.Line] {
        defer {
            if let store, let rows = try? loadLibraryRows(store: store) { libraryItems = rows }
            refreshSelectedItem()
        }
        // The edition files are read and written off the main thread (#2510); the store steps stay here, in order.
        return await ListeningEditionBatch.runAsync(entries, existing: { edition in
            guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
            let saved = try await Self.offMain { try Self.savedListeningEditionState(of: edition) }
            if saved == .missing { return .none }
            if saved == .different { return .different }
            // Saved edition but the item or its map is gone from the Library (or the import stopped after the file was
            // written, because playback began): import it again. Neither read decodes the text or the map (#2506).
            guard let store = try? requireStore() else { return .none }
            let itemIsThere = (try? store.loadItemSummary(id: edition.itemID)) != nil
            let mapIsThere = (try? store.listeningMapId(itemId: edition.itemID)) != nil
            return itemIsThere && mapIsThere ? .identical : .none
        }, importOne: { edition in
            try await saveListeningEdition(edition, replaceMap: false)
            schedulePrewarmAfterPreparedTextChange(itemId: edition.itemID)
        })
    }

    /// Collection files picked from the Add sheet's Files route (#2373). Like a PDF added there, they land in the
    /// Library and nothing opens or plays. Returns whether every file went in, so the sheet knows to close.
    @discardableResult
    func importListeningEditionFiles(_ urls: [URL], folders: [URL] = []) async -> Bool {
        // The folders are walked and the files read and decoded off the main thread (#2510, #2256); each edition's
        // file is read and written off it too, and only the store steps run here.
        let loaded = await Task.detached(priority: .userInitiated) { Self.readListeningEditionEntries(urls, folders: folders) }.value
        if loaded.entries.isEmpty {
            reportFailure(ListeningEditionFolderWalk.emptyMessage(folderNames: folders.map(\.lastPathComponent)))
            return false
        }
        let lines = await importListeningEditions(loaded.entries)
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
                await importListeningEditionData(data)
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

    func importListeningEditionDataForShortcut(_ data: Data) async throws {
        try await performListeningEditionImport(data, replaceMap: false)
    }

    private func performListeningEditionImport(_ data: Data, replaceMap: Bool) async throws {
        guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
        try await openAfterImporting(try ListeningEdition.decode(data), replaceMap: replaceMap)
    }

    private func openAfterImporting(_ edition: ListeningEdition, replaceMap: Bool) async throws {
        try await saveListeningEdition(edition, replaceMap: replaceMap)
        let store = try requireStore()
        activeItemId = edition.itemID
        libraryItems = try loadLibraryRows(store: store)
        refreshSelectedItem()
        screen = .item
        schedulePrewarmAfterPreparedTextChange(itemId: edition.itemID)
        reportConfirmation("Imported item and Listening Map. Audio prepares separately; playback has not started.")
    }

    /// Saves the item, the edition and its map. Navigates nowhere.
    ///
    /// The edition's file is read and written off the main thread (#2510): it can be megabytes. The steps keep their
    /// old order (check for a different map, save the item, check playback, write the file, attach the map); the
    /// store steps stay on the main thread, and playback is checked again after the write, since the listener can
    /// press play while it runs.
    private func saveListeningEdition(_ edition: ListeningEdition, replaceMap: Bool) async throws {
        guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
        if !replaceMap, try await Self.offMain({ try Self.savedListeningEditionState(of: edition) }) == .different {
            throw EditionError.invalid("This source already has a different Listening Map. To replace it, preview this edition (Review on its own, or paste it) in Import Listening Edition and turn on Replace.")
        }
        let store = try requireStore()
        let itemId = edition.itemID
        // The item (its text can be megabytes), the map and the audio map are written off the main thread (#2509), in
        // the order they always had; the engine is told on main afterwards, and playback is checked again first.
        // Stable source identity preserves every existing session and Margin on retry.
        try await Self.offMain {
            if (try? store.loadItemSummary(id: itemId)) == nil { // whether it is there, not its text (#2506)
                try store.saveItem(Item(id: itemId, title: edition.title, mediaType: "text", text: edition.text,
                                       externalReference: edition.sourceURL, status: "ready", externalReferenceType: "url", createdAt: Date()))
            }
        }
        try requireNoPlaybackForListeningEdition(itemId: itemId)
        try await Self.offMain { try ListeningEditionStore.application().save(edition) }
        try requireNoPlaybackForListeningEdition(itemId: itemId)
        let persister = try engine?.listeningMapPersister()
        let written = try await Self.offMain { () -> (PersistedListeningMap?, TranscriptTimeline?) in
            let map = edition.listeningMap()
            var persisted: PersistedListeningMap?
            if let persister { persisted = try persister.persist(map) } else { try store.saveListeningMap(map) }
            return (persisted, try store.loadTranscriptTimeline(itemId: itemId)?.timeline)
        }
        // The listener may have pressed play on this item while the write ran: the map is saved, and the engine takes
        // it the next time the item opens, as for a shared map ("left alone until the listener pauses").
        let playingNow = snapshot.itemId == itemId && snapshot.status.isPlaybackActive
        try hangTelemetry.labels.scoped("listeningEdition.attach") {
            if let engine, let persisted = written.0, !playingNow { snapshot = try engine.attachListeningMap(persisted) }
        }
        if let timeline = written.1 {
            await activateListeningEditionAudioOffMain(itemId: itemId, timeline: timeline)
        }
    }

    /// Saves the audio map an edition's timeline resolves to, off the main thread (#2509), then tells the screen.
    func activateListeningEditionAudioOffMain(itemId: String, timeline: TranscriptTimeline) async {
        guard let edition = await saveListeningEditionAudioMap(itemId: itemId, timeline: timeline) else { return }
        hangTelemetry.labels.scoped("listeningEdition.activateAudio") { finishListeningEditionAudio(itemId: itemId, edition: edition) }
    }

    /// The store half: the edition's audio map and its projection. Nil when there is no edition file or the map
    /// could not be saved (the second case is noted in the diagnostics).
    func saveListeningEditionAudioMap(itemId: String, timeline: TranscriptTimeline) async -> ListeningEdition? {
        guard let store else { return nil }
        do {
            return try await Self.offMain { () -> ListeningEdition? in
                guard let edition = try? ListeningEditionStore.application().load(itemID: itemId) else { return nil }
                let (proposal, projection) = try edition.audioMap(timeline: timeline)
                try store.savePortableListeningMapProposal(proposal, itemId: itemId)
                try store.saveResolvedListeningMapProjection(projection)
                return edition
            }
        } catch {
            diagnostics["listeningEditionAudio"] = "not_ready"
            return nil
        }
    }

    /// What follows a saved audio map, on the main thread: the open screen refreshes and the listener is told.
    func finishListeningEditionAudio(itemId: String, edition: ListeningEdition) {
        if selectedItem.id == itemId { refreshSelectedItemInBackground() }
        prepareImportedLocalAudioBridges(itemId: itemId)
        Task { await ListeningReadyNotifications.notify(itemID: itemId, title: edition.title, revision: edition.revision) }
    }

    private func requireNoPlaybackForListeningEdition(itemId: String) throws {
        if snapshot.itemId == itemId, snapshot.status.isPlaybackActive {
            throw EditionError.invalid("Pause playback before importing a map for the current item.")
        }
    }

    /// What the edition file for this source holds compared with `edition`, read where the file is (off main).
    private enum SavedListeningEditionState { case missing, identical, different }

    private nonisolated static func savedListeningEditionState(of edition: ListeningEdition) throws -> SavedListeningEditionState {
        guard let previous = try ListeningEditionStore.application().load(itemID: edition.itemID) else { return .missing }
        return previous == edition ? .identical : .different
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
