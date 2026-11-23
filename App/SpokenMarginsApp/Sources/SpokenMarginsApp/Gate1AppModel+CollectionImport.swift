import Foundation
import SessionKit
import SessionKitPersistence

/// A folder or a titled link list picked in Files becomes a collection (#3769), quietly. The rules (which files are new,
/// where each item goes, what the last line says) are `LibraryCollectionImport` in SessionKit; this file only runs the
/// importers a single pick already uses, one file at a time in folder order, with a `CollectionImportCapture` set so
/// none of them puts up its own banner. The collection row is saved before the first file, and fills in as each lands.
extension Gate1AppModel {
    static let collectionImportBusyMessage = "Another folder is still being added. Try again when it's done."

    /// A folder picked in Files: its PDFs, text, Markdown, EPUBs, audio, Listening Editions and link lists, in file order.
    /// Picking the same folder again adds only what is new. Returns the last line, or nil when nothing started.
    @discardableResult
    func importFolderAsCollection(_ folder: URL) async -> LibraryCollectionImport.Summary? {
        guard libraryCollections.importCapture == nil else { reportPastImportCapture { reportFailure(Self.collectionImportBusyMessage) }; return nil }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Couldn't add the folder"); return nil }
        // Busy from here, before the walk's await, so a second pick during the walk is turned away (#3769).
        let capture = CollectionImportCapture()
        libraryCollections.importCapture = capture
        defer { libraryCollections.importCapture = nil }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let walk = await Task.detached(priority: .userInitiated) { LibraryFolderWalk.walk(folder) }.value
        let start = LibraryCollectionImport.start(
            walk: walk, pickedPath: LibraryFolderRecord.standardizedPath(of: folder),
            bookmark: try? folder.bookmarkData(), name: folder.lastPathComponent,
            folders: libraryCollections.folders, collections: libraryCollections.collections, now: Date(),
            collectionID: "collection-\(UUID().uuidString)", makeItemID: Self.collectionImportItemID)
        let result = await runCollectionImport(start, capture: capture, store: store)
        return result?.deleted == true ? nil : result?.summary
    }

    /// What a finished collection import tells its caller (#4683): the line to show, which collection it filled, whether
    /// the pick made it, the items it saved, and how many links or files failed.
    struct CollectionImportResult {
        var summary: LibraryCollectionImport.Summary
        var collectionID: String
        var isNew: Bool
        var addedItemIDs: [String]
        var failed: Int
        /// The listener deleted the collection while it filled. The items that landed are in the Library, and the
        /// collection stays deleted; this is not a failure, so nothing is retried.
        var deleted = false
    }

    /// A link list with a title, picked in Files: a collection of its links in the list's order. Picking the same list
    /// again adds only its new links. Follow entries are never members: they go to the shows the listener's AI suggested.
    @discardableResult
    func importLinkListAsCollection(_ url: URL, list: LinkListFile, title: String) async -> LibraryCollectionImport.Summary? {
        let suggested = suggestShows(from: list)
        let itemList = LinkListFile(title: list.title, entries: list.entries.filter { !$0.follow }, skipped: list.skipped)
        guard !itemList.entries.isEmpty else {
            // Only shows to follow: no collection to make.
            let banner = LinkListArrivalPlan.banner(
                base: nil, suggested: suggested, madeItems: false, isTitled: true, collectionIsNew: false, mentionsFollowing: false)
            reportConfirmation(banner.message)
            return LibraryCollectionImport.Summary(message: banner.message, kind: banner.kind)
        }
        let result = await importLinkListAsCollection(
            pickedPath: LibraryFolderRecord.standardizedPath(of: url), walkName: url.lastPathComponent, list: itemList, title: title,
            reportsBanner: true, onboarding: [.addedOwnSource, .addedFromFiles])
        return result?.deleted == true ? nil : result?.summary
    }

    /// A link list that arrived (#4683): the same collection whichever way it came, because its path is the list's
    /// own key (`LinkListArrivalPlan.key`) and not a file's. With `reportsBanner` false the arrival says it itself.
    @discardableResult
    func importLinkListAsCollection(
        key: String, list: LinkListFile, title: String, reportsBanner: Bool, onboarding: Set<OnboardingStep>
    ) async -> CollectionImportResult? {
        await importLinkListAsCollection(
            pickedPath: key, walkName: key, list: list, title: title, reportsBanner: reportsBanner, onboarding: onboarding)
    }

    private func importLinkListAsCollection(
        pickedPath: String, walkName: String, list: LinkListFile, title: String, reportsBanner: Bool, onboarding: Set<OnboardingStep>
    ) async -> CollectionImportResult? {
        guard libraryCollections.importCapture == nil else { reportPastImportCapture { reportFailure(Self.collectionImportBusyMessage) }; return nil }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Couldn't add the list"); return nil }
        // Only this list's own link imports report to it: a share that drains meanwhile keeps its item and banner (#4683).
        let capture = CollectionImportCapture(membersOnly: true)
        libraryCollections.importCapture = capture
        defer { libraryCollections.importCapture = nil }
        let start = LibraryCollectionImport.start(
            walk: LibraryFolderWalk.linkList(list, named: walkName),
            pickedPath: pickedPath, bookmark: nil, name: title,
            folders: libraryCollections.folders, collections: libraryCollections.collections, now: Date(),
            collectionID: "collection-\(UUID().uuidString)", makeItemID: Self.collectionImportItemID)
        return await runCollectionImport(start, capture: capture, store: store, reportsBanner: reportsBanner, onboarding: onboarding)
    }

    nonisolated static func collectionImportItemID() -> String { "item-collection-\(UUID().uuidString.lowercased())" }

    /// Runs a started import. The caller holds `capture` set as `importCapture` until this returns. Each file's result is
    /// written to the collection as it is stored at that moment (`LibraryCollectionModel.update`), so a rename, an edit or
    /// a delete made while the import runs is kept; a deleted collection ends the import (#3769).
    private func runCollectionImport(
        _ start: LibraryCollectionImport.Start, capture: CollectionImportCapture, store: SQLiteSessionStore,
        reportsBanner: Bool = true, onboarding: Set<OnboardingStep> = [.addedOwnSource, .addedFromFiles]
    ) async -> CollectionImportResult? {
        guard LibraryCollectionImport.savesCollection(start) else {
            let summary = LibraryCollectionImport.summary(
                name: start.collection.name, isNew: true, added: 0, failed: 0, notAdded: start.record.notAdded.count)
            if reportsBanner { reportPastImportCapture { present(summary) } }
            return CollectionImportResult(summary: summary, collectionID: start.collection.id, isNew: true, addedItemIDs: [], failed: 0)
        }
        let id = start.collection.id
        var name = start.collection.name
        // What a re-pick's collection already held, so a retry that only loses links says what it holds (#5071).
        let held = start.isNew ? 0 : start.collection.itemIDs.count
        // Every write carries the jobs settled since the last good one, so a failed write never leaves the stored record
        // saying `added` for an item its collection lacks (#3769 audit).
        var settling = LibraryCollectionImport.Settling(record: start.record)
        switch await libraryCollections.startImport(start.collection, isNew: start.isNew, record: start.record, store: store) {
        case .saved(let stored, _): name = stored.name
        case .gone, .refused: return nil
        case .failed(let error):
            reportPastImportCapture { reportFailure(error, context: "Couldn't add “\(name)”") }
            return nil
        }
        var added = 0
        var failed = 0
        var deleted = false
        var addedItemIDs: [String] = []
        for job in start.jobs {
            let outcome = await importCollectionMember(job, capture: capture, store: store)
            if case .added(let itemID) = outcome { added += 1; addedItemIDs.append(itemID) } else { failed += 1 }
            settling.settle(job, outcome: outcome, now: Date())
            let record = settling.record
            let pending = settling
            let result = await libraryCollections.update(id, record: record, store: store) { current, _ in
                pending.collection(from: current)
            }
            switch result {
            case .saved(let stored, _):
                name = stored.name
                settling.didSave(record)
            case .gone: deleted = true
            case .refused: break
            case .failed(let error):
                // The next write carries this job too. If none succeeds, the stored record still has its member `adding`,
                // and the next launch puts a saved item in the collection (`LibraryFolderLaunchRule`).
                diagnostics["collectionImportSaveFailure"] = SafeErrorText.describe(error)
            }
            if deleted { break }
        }
        _ = try? await reloadLibraryRowsOffMain(store: store)
        if added > 0 { markOnboardingSteps(onboarding) }
        // Deleted while it filled: the items that landed are in the Library, and the listener chose to drop the collection.
        guard !deleted else {
            return CollectionImportResult(
                summary: LibraryCollectionImport.summary(
                    name: name, isNew: start.isNew, added: added, failed: failed, notAdded: settling.record.notAdded.count,
                    held: held),
                collectionID: id, isNew: start.isNew, addedItemIDs: addedItemIDs, failed: failed, deleted: true)
        }
        let summary = LibraryCollectionImport.summary(
            name: name, isNew: start.isNew, added: added, failed: failed, notAdded: settling.record.notAdded.count,
            held: held)
        if reportsBanner { reportPastImportCapture { present(summary) } }
        return CollectionImportResult(
            summary: summary, collectionID: id, isNew: start.isNew, addedItemIDs: addedItemIDs, failed: failed)
    }

    /// Shows what the import itself means the listener to see (#3769 audit). `presentFeedback` hands every event with no
    /// item origin to the capture that is set, so the import's own lines, and the busy line a second pick gets while one
    /// runs, would be held and never shown. The capture is lifted only for `report`, which is synchronous on the main
    /// actor, so no importer can report in between, then put back for an import that is still running.
    func reportPastImportCapture(_ report: () -> Void) {
        let capture = libraryCollections.importCapture
        libraryCollections.importCapture = nil
        defer { libraryCollections.importCapture = capture }
        report()
    }

    private func present(_ summary: LibraryCollectionImport.Summary) {
        switch summary.kind {
        case .success: reportConfirmation(summary.message)
        case .warning: reportWarning(summary.message)
        case .failure: reportFailure(summary.message)
        }
    }

    // MARK: - One file or link

    /// Imports one member with the importer a single pick of it uses, and says how it ended.
    private func importCollectionMember(
        _ job: LibraryFolderMerge.Job, capture: CollectionImportCapture, store: SQLiteSessionStore
    ) async -> LibraryCollectionImport.Outcome {
        let walked = job.walkMember
        if walked.kind == .link {
            guard let address = walked.address else { return .failed(reason: LibraryCollectionImport.noItemReason, retryable: false) }
            _ = capture.take()
            _ = await CollectionImportMemberContext.$isActive.withValue(true) {
                await importSourceLinkAsync(urlString: address, sourceSurface: "link_list", startSession: false)
            }
            let taken = capture.take()
            if let itemID = taken.itemIDs.first { return .added(itemID: itemID) }
            return .failed(reason: taken.problem ?? LibraryCollectionImport.noItemReason, retryable: true)
        }
        guard let url = walked.url else { return .failed(reason: LibraryCollectionImport.noItemReason, retryable: false) }
        if walked.isNotDownloaded, !(await Self.downloadFromICloud(url)) {
            return .failed(reason: LibraryCollectionImport.notDownloadedReason, retryable: true)
        }
        do {
            switch walked.kind {
            case .pdf, .text, .markdown:
                return try await importCollectionDocument(url, itemID: job.itemID ?? Self.collectionImportItemID(), store: store)
            case .epub:
                let item = try await requireLocalSourceImporter().importEPUB(from: url, itemId: job.itemID)
                scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
                return .added(itemID: item.id)
            case .audio:
                let item = try await requireLocalSourceImporter().importAudiobook(from: url, itemId: job.itemID)
                refreshSpokenMarginsPackageImportAfterAddingSource()
                return .added(itemID: item.id)
            case .edition:
                return try await importCollectionEdition(url)
            case .link:
                return .failed(reason: LibraryCollectionImport.noItemReason, retryable: false)
            }
        } catch LocalSourceImportError.duplicate {
            return .failed(reason: ListenerErrorText.message(for: LocalSourceImportError.duplicate), retryable: false)
        } catch {
            return .failed(reason: ListenerErrorText.message(for: error), retryable: true)
        }
    }

    /// Text, Markdown and PDF, read and saved off the main actor the way a pick of them is, under the ID the record holds.
    private func importCollectionDocument(_ url: URL, itemID: String, store: SQLiteSessionStore) async throws -> LibraryCollectionImport.Outcome {
        let request = ObsidianImportRequest(url: url, itemId: itemID)
        let originalStore = try? pdfOriginalStore()
        let batch = await Task.detached(priority: .userInitiated) {
            await Self.prepareObsidianImports([request], originalStore: originalStore)
        }.value
        let clipStore = pdfClipStore()
        let written: SavedObsidianImports
        do {
            written = try await Self.offMain {
                Self.saveObsidianImports(batch.prepared, staged: batch.staged, originalStore: originalStore, store: store, clipStore: clipStore)
            }
        } catch {
            // Nothing was saved, so no staged copy will become an original (#4338).
            if let originalStore { batch.staged.values.forEach(originalStore.discard) }
            throw error
        }
        guard written.imported.contains(where: { $0.id == itemID }) else {
            // A failure line is "file name\nreason"; the collection's "Couldn't add" list already names the file.
            let line = (batch.failures + written.failures).first ?? LibraryCollectionImport.noItemReason
            return .failed(reason: line.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? line, retryable: true)
        }
        if engine == nil { installEngine(try makeEngine(store: store)) }
        scheduleTextAudioPrewarmIfNeeded(itemId: itemID)
        return .added(itemID: itemID)
    }

    /// A Listening Edition: its item's ID is the edition's own, known once the file is read.
    private func importCollectionEdition(_ url: URL) async throws -> LibraryCollectionImport.Outcome {
        let data = try await Self.offMain { () throws -> Data in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8_000_000 else { throw EditionError.invalid("Listening edition exceeds 8 MB.") }
            return try Data(contentsOf: url)
        }
        let entry = ListeningEditionBatch.Entry(id: 0, name: url.lastPathComponent, data: data)
        guard let edition = entry.edition else {
            return .failed(reason: entry.error ?? LibraryCollectionImport.noItemReason, retryable: false)
        }
        let outcome = await importListeningEditions([entry]).first?.outcome
        switch outcome {
        case .imported, .alreadyImported, .keptExistingMap: return .added(itemID: edition.itemID)
        case .failed(let reason): return .failed(reason: reason, retryable: true)
        case nil: return .failed(reason: LibraryCollectionImport.noItemReason, retryable: true)
        }
    }

    /// Asks iCloud for a file that is not on the device yet and waits for it, for at most a minute. False when it did not
    /// arrive; the member can be tried again by importing the folder again.
    nonisolated static func downloadFromICloud(_ url: URL) async -> Bool {
        do { try FileManager.default.startDownloadingUbiquitousItem(at: url) } catch { return false }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            var probe = url
            probe.removeAllCachedResourceValues()
            let status = try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == .current || (status == nil && FileManager.default.fileExists(atPath: url.path)) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
