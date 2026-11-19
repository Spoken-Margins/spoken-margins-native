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
        guard libraryCollections.importCapture == nil else { reportFailure(Self.collectionImportBusyMessage); return nil }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Couldn't add the folder"); return nil }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let walk = await Task.detached(priority: .userInitiated) { LibraryFolderWalk.walk(folder) }.value
        let start = LibraryCollectionImport.start(
            walk: walk, pickedPath: LibraryFolderRecord.standardizedPath(of: folder),
            bookmark: try? folder.bookmarkData(), name: folder.lastPathComponent,
            folders: libraryCollections.folders, collections: libraryCollections.collections, now: Date(),
            collectionID: "collection-\(UUID().uuidString)", makeItemID: Self.collectionImportItemID)
        return await runCollectionImport(start, store: store)
    }

    /// A link list with a title, picked in Files: a collection of its links in the list's order. Picking the same list
    /// again adds only its new links.
    @discardableResult
    func importLinkListAsCollection(_ url: URL, list: LinkListFile, title: String) async -> LibraryCollectionImport.Summary? {
        guard libraryCollections.importCapture == nil else { reportFailure(Self.collectionImportBusyMessage); return nil }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch { reportFailure(error, context: "Couldn't add the list"); return nil }
        let start = LibraryCollectionImport.start(
            walk: LibraryFolderWalk.linkList(list, named: url.lastPathComponent),
            pickedPath: LibraryFolderRecord.standardizedPath(of: url), bookmark: nil, name: title,
            folders: libraryCollections.folders, collections: libraryCollections.collections, now: Date(),
            collectionID: "collection-\(UUID().uuidString)", makeItemID: Self.collectionImportItemID)
        return await runCollectionImport(start, store: store)
    }

    nonisolated static func collectionImportItemID() -> String { "item-collection-\(UUID().uuidString.lowercased())" }

    private func runCollectionImport(_ start: LibraryCollectionImport.Start, store: SQLiteSessionStore) async -> LibraryCollectionImport.Summary? {
        guard LibraryCollectionImport.savesCollection(start) else {
            let summary = LibraryCollectionImport.summary(
                name: start.collection.name, isNew: true, added: 0, failed: 0, notAdded: start.record.notAdded.count)
            present(summary)
            return summary
        }
        var collection = start.collection
        var record = start.record
        if let error = await libraryCollections.saveImport(collection, record: record, store: store) {
            reportFailure(error, context: "Couldn't add “\(collection.name)”")
            return nil
        }
        let capture = CollectionImportCapture()
        libraryCollections.importCapture = capture
        defer { libraryCollections.importCapture = nil }
        var added = 0
        var failed = 0
        for job in start.jobs {
            let outcome = await importCollectionMember(job, capture: capture, store: store)
            LibraryCollectionImport.settle(job, outcome: outcome, record: &record, collection: &collection, now: Date())
            if case .added = outcome { added += 1 } else { failed += 1 }
            if let error = await libraryCollections.saveImport(collection, record: record, store: store) {
                // The items are saved; the next launch puts any that missed the collection back in (`LibraryFolderLaunchRule`).
                diagnostics["collectionImportSaveFailure"] = String(describing: error)
            }
        }
        _ = try? await reloadLibraryRowsOffMain(store: store)
        if added > 0 { markOnboardingSteps([.addedOwnSource, .addedFromFiles]) }
        libraryCollections.importCapture = nil
        let summary = LibraryCollectionImport.summary(
            name: collection.name, isNew: start.isNew, added: added, failed: failed, notAdded: record.notAdded.count)
        present(summary)
        return summary
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
            _ = await importSourceLinkAsync(urlString: address, sourceSurface: "link_list", startSession: false)
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
        let batch = await Task.detached(priority: .userInitiated) { await Self.prepareObsidianImports([request]) }.value
        let clipStore = pdfClipStore()
        let written = try await Self.offMain { Self.saveObsidianImports(batch.prepared, store: store, clipStore: clipStore) }
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
