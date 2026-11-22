import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitEPUB
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Text, EPUB, audiobook and Obsidian file import (#970), moved unchanged out of the central model.
extension Gate1AppModel {
    func importTextItem(startListening: Bool = true) {
        do {
            let store = try requireStore()
            let preservesActiveSession = !startListening && hasActiveSession && engine != nil
            let itemId = "item-import-\(UUID().uuidString.lowercased())"
            let enteredTitle = importTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try ObsidianMarkdownParser.parse(
                fileName: enteredTitle.isEmpty ? "\(importText.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")).md" : "\(enteredTitle).md",
                contents: importText,
                titleOverride: enteredTitle.isEmpty ? nil : enteredTitle
            )
            let deterministicMap = parsed.deterministicListeningMap(itemId: itemId, policy: .authoredSections)
            let item = Item(
                id: itemId,
                title: enteredTitle.isEmpty ? parsed.title : enteredTitle,
                mediaType: "text",
                text: parsed.text,
                externalReference: "manual-import",
                status: deterministicMap == nil ? "needs_listening_map" : "ready",
                externalReferenceType: "manual"
            )
            try store.seed(item: item)
            if let deterministicMap {
                try store.saveListeningMap(deterministicMap)
                diagnostics["lastListeningMapMode"] = "deterministic_headings"
                diagnostics["lastGeneratedMapItem"] = item.id
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
            libraryItems = try loadLibraryRows(store: store)
            if !preservesActiveSession && startListening {
                activeItemId = item.id
                selectedItem = try loadItemDetail(id: item.id, store: store)
            }
            diagnostics["lastImport"] = item.id
            markOnboardingSteps([.addedOwnSource])
            importTitle = ""
            importText = ""
            if startListening {
                startItem(id: item.id)
            } else {
                reportAddedToLibrary(title: item.title, itemId: item.id)
            }
        } catch {
            reportFailure(error, context: "Import failed")
        }
    }

    func pasteImportTextFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain text.")
            return
        }
        let html = UIPasteboard.general.data(forPasteboardType: "public.html")
            .flatMap { $0.count <= 2_000_000 ? String(data: $0, encoding: .utf8) : nil }
        importText = Self.pastedSourceText(plainText: clipboardText, html: html)
        reportSuccess("Pasted text from Clipboard.")
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    func importObsidianMarkdownFiles(urls: [URL]) {
        beginObsidianMarkdownImport(urls: urls, securityScopedURLs: urls)
    }

    func importEPUBFile(url: URL, openWhenFinished: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let importer = try self.requireLocalSourceImporter()
                let item = try await importer.importEPUB(from: url)
                guard let store = self.store else { return }
                try await self.reloadLibraryRowsOffMain(store: store)
                self.markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                self.scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
                if openWhenFinished {
                    self.selectedItem = try await self.loadItemDetailOffMain(id: item.id, store: store)
                    self.activeItemId = item.id
                    self.screen = .item
                    self.reportConfirmation("Imported \(item.title).")
                } else {
                    self.reportAddedToLibrary(title: item.title, itemId: item.id)
                }
            } catch {
                self.reportFailure(error, context: "EPUB import failed")
            }
        }
    }

    func importAudiobookFile(url: URL, openWhenFinished: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let importer = try self.requireLocalSourceImporter()
                let item = try await importer.importAudiobook(from: url)
                guard let store = self.store else { return }
                try await self.reloadLibraryRowsOffMain(store: store)
                self.markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                self.refreshSpokenMarginsPackageImportAfterAddingSource()
                if openWhenFinished {
                    self.selectedItem = try await self.loadItemDetailOffMain(id: item.id, store: store)
                    self.activeItemId = item.id
                    self.screen = .item
                    self.reportConfirmation("Imported \(item.title).")
                } else {
                    self.reportAddedToLibrary(title: item.title, itemId: item.id)
                }
            } catch {
                self.reportFailure(error, context: "Audiobook import failed")
            }
        }
    }

    var isImportingSources: Bool {
        sourceImportProgressMessage != nil
    }

    func beginObsidianMarkdownImport(
        urls: [URL],
        securityScopedURLs: [URL],
        refreshQuickFolderWhenFinished: Bool = false,
        openImportedItemWhenFinished: Bool = false,
        quickAccessFileToDismiss: QuickAccessFile? = nil,
        onImported: (([Item]) -> Void)? = nil,
        onFinished: (([Item]) -> Void)? = nil,
        navigatesWhenFinished: Bool = true,
        confirmationOverride: ((Int) -> String)? = nil,
        summary: ((_ importedCount: Int, _ failedFileNames: [String]) -> Void)? = nil
    ) {
        guard !urls.isEmpty else {
            reportFailure("Choose at least one Markdown, text, or PDF file to import.")
            return
        }
        guard sourceImportTask == nil else {
            reportFailure("Another source is already importing. You can keep using playback while it finishes.")
            return
        }

        let requests = urls.enumerated().map { index, url in
            ObsidianImportRequest(
                url: url,
                itemId: obsidianItemId(fileName: url.lastPathComponent, index: index)
            )
        }
        let scopedAccess = securityScopedURLs.map { url in
            (url: url, didAccess: url.startAccessingSecurityScopedResource())
        }
        sourceImportProgressMessage = urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) files…"
        statusMessage = sourceImportProgressMessage ?? "Importing sources…"
        lastError = nil

        let originalStore = try? pdfOriginalStore()
        sourceImportTask = Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                await Self.prepareObsidianImports(requests, originalStore: originalStore)
            }.value
            scopedAccess.forEach { entry in
                if entry.didAccess {
                    entry.url.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            // The item, map and document saves run off the main actor (#2509), as the reads after them do (#2505).
            let saved: Result<SavedObsidianBatch, Error>
            do {
                let store = try self.requireStore()
                let clipStore = self.pdfClipStore()
                let written = try await Self.offMain {
                    Self.saveObsidianImports(batch.prepared, staged: batch.staged, originalStore: originalStore, store: store, clipStore: clipStore)
                }
                saved = self.hangTelemetry.labels.scoped("obsidianImportFinish") {
                    Result { try self.completeObsidianMarkdownImport(batch, written: written, store: store) }
                }
            } catch {
                // Nothing was saved, so no staged copy will become an original.
                if let originalStore { batch.staged.values.forEach(originalStore.discard) }
                saved = .failure(error)
            }
            await self.finishObsidianMarkdownImport(
                saved,
                refreshQuickFolderWhenFinished: refreshQuickFolderWhenFinished,
                openImportedItemWhenFinished: openImportedItemWhenFinished,
                quickAccessFileToDismiss: quickAccessFileToDismiss,
                onImported: onImported,
                onFinished: onFinished,
                navigatesWhenFinished: navigatesWhenFinished,
                confirmationOverride: confirmationOverride,
                summary: summary
            )
        }
    }

    nonisolated static func prepareObsidianImports(
        _ requests: [ObsidianImportRequest], originalStore: PDFOriginalStore?
    ) async -> ObsidianImportBatch {
        var prepared: [PreparedObsidianImport] = []
        var failures: [String] = []
        var rawFailures: [String] = []
        var staged: [String: PDFOriginalStore.Staged] = [:]
        var stagingFailures: [String] = []
        for request in requests {
            var stagedCopy: PDFOriginalStore.Staged?
            do {
                let read = try await importableText(
                    from: request.url, itemId: request.itemId, originalStore: originalStore, stagingFailures: &stagingFailures)
                stagedCopy = read.1
                prepared.append(try SourceFileItemBuilder.prepare(
                    read.0, fileURL: request.url, itemId: request.itemId, createdAt: Date()
                ))
                // A file address and a hash, not the bytes: a batch of large PDFs stays small (#4338).
                staged[request.itemId] = stagedCopy
            } catch {
                if let stagedCopy { originalStore?.discard(stagedCopy) }
                failures.append("\(request.url.lastPathComponent)\n\(ListenerErrorText.message(for: error))")
                rawFailures.append("\(request.url.lastPathComponent): \(error)")
            }
        }
        return ObsidianImportBatch(
            prepared: prepared, failures: failures, rawFailures: rawFailures, staged: staged, stagingFailures: stagingFailures)
    }

    /// The file's text and, for a PDF or a Word document, a staged copy to keep beside the item (#4338, #4594). The picked
    /// file's access is open here and ends before the item is saved, so the copy is made now, a chunk at a time. A PDF's
    /// text is read from the copy so the hash recorded on the document is the hash of the file that is kept. When no copy
    /// can be made, the text is read from the picked file as before and the import goes on without an original.
    private nonisolated static func importableText(
        from url: URL, itemId: String, originalStore: PDFOriginalStore?, stagingFailures: inout [String]
    ) async throws -> (ImportedSourceText, PDFOriginalStore.Staged?) {
        if WordDocumentImport.handles(url) {
            // Read first, so a refused file stages nothing; the bytes go once it's read, and the batch holds only the copy.
            let imported = try WordDocumentImport.read(url: url).imported
            return (imported, stage(url, itemId: itemId, kind: .docx, originalStore: originalStore, failures: &stagingFailures))
        }
        guard url.pathExtension.lowercased() == "pdf" else {
            return (ImportedSourceText(
                text: try String(contentsOf: url, encoding: .utf8),
                documentStructure: nil
            ), nil)
        }
        #if canImport(PDFKit)
        let staged = stage(url, itemId: itemId, kind: .pdf, originalStore: originalStore, failures: &stagingFailures)
        do {
            let extracted = try NativePDFDocumentExtractor.extractStructured(fromFile: staged?.url ?? url, sourceSHA256: staged?.sha256)
            return (ImportedSourceText(
                text: extracted.document.text,
                documentStructure: extracted.documentStructure,
                structuredDocument: extracted.document,
                title: extracted.title,
                clips: extracted.clips
            ), staged)
        } catch PDFStructuredTextExtractor.ExtractionError.noExtractableText {
            if let staged { originalStore?.discard(staged) }
            throw SourceFileImportError.pdfHasNoExtractableText
        } catch {
            if let staged { originalStore?.discard(staged) }
            throw error
        }
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    /// A copy of the picked file in its item's folder, or nil with the reason added to `failures`.
    private nonisolated static func stage(
        _ url: URL, itemId: String, kind: PDFOriginalStore.Kind, originalStore: PDFOriginalStore?, failures: inout [String]
    ) -> PDFOriginalStore.Staged? {
        do {
            guard let originalStore else { throw CocoaError(.fileNoSuchFile) }
            return try originalStore.stage(copying: url, itemId: itemId, kind: kind)
        } catch {
            failures.append(SafeErrorText.describe(error))
            return nil
        }
    }

    /// What `completeObsidianMarkdownImport` leaves for the finish: the saved items, the failures, and where the listener was.
    private struct SavedObsidianBatch {
        var imported: [Item]
        var failures: [String]
        var rawFailures: [String]
        var preservesActiveSession: Bool
        var preservedActiveItemId: String
        var preservedSelectedItemId: String
    }

    /// What the import leaves once its files are saved: where the listener was, and an engine if there was none.
    private func completeObsidianMarkdownImport(
        _ batch: ObsidianImportBatch, written: SavedObsidianImports, store: SQLiteSessionStore
    ) throws -> SavedObsidianBatch {
        if let reason = (batch.stagingFailures + written.originalKeepFailures).first { diagnostics["lastPDFOriginalKeepFailure"] = reason } // #4338
        let saved = SavedObsidianBatch(
            imported: written.imported, failures: batch.failures + written.failures,
            rawFailures: batch.rawFailures + written.rawFailures,
            preservesActiveSession: hasActiveSession && engine != nil,
            preservedActiveItemId: activeItemId, preservedSelectedItemId: selectedItem.id)
        if !saved.imported.isEmpty, engine == nil {
            installEngine(try makeEngine(store: store))
        }
        return saved
    }

    struct SavedObsidianImports: Sendable {
        var imported: [Item] = []
        var failures: [String] = []
        var rawFailures: [String] = []
        /// Why a saved PDF's original was not kept; the import itself still counts (#4338).
        var originalKeepFailures: [String] = []
    }

    /// Saves each prepared file's item, map and document off the main actor (#2509): the text can be megabytes.
    nonisolated static func saveObsidianImports(
        _ prepared: [PreparedObsidianImport], staged: [String: PDFOriginalStore.Staged], originalStore: PDFOriginalStore?,
        store: SQLiteSessionStore, clipStore: PDFClipStore?
    ) -> SavedObsidianImports {
        var result = SavedObsidianImports()
        var unsaved = staged
        defer { if let originalStore { unsaved.values.forEach(originalStore.discard) } } // an item that did not save keeps no copy
        for prepared in prepared {
            do {
                try store.saveItem(prepared.item)
                if let listeningMap = prepared.listeningMap {
                    try store.saveListeningMap(listeningMap)
                }
                if let document = prepared.structuredDocument {
                    try store.saveStructuredDocument(document, itemId: prepared.item.id)
                    // The item is saved; a picture that can't be written only leaves its row as text (#3895).
                    try? clipStore?.replaceClips(prepared.clips, forItem: prepared.item.id, document: document)
                }
                result.imported.append(prepared.item)
                // After the item is saved, so a failed save leaves no original behind. A failed write loses only the copy.
                if let copy = unsaved.removeValue(forKey: prepared.item.id) {
                    do {
                        guard let originalStore else { throw CocoaError(.fileNoSuchFile) }
                        try originalStore.commit(copy)
                    } catch {
                        result.originalKeepFailures.append(SafeErrorText.describe(error))
                    }
                }
            } catch {
                result.failures.append("\(prepared.item.title)\n\(ListenerErrorText.message(for: error))")
                result.rawFailures.append("\(prepared.item.title): \(error)")
            }
        }
        return result
    }

    private func finishObsidianMarkdownImport(
        _ result: Result<SavedObsidianBatch, Error>,
        refreshQuickFolderWhenFinished: Bool,
        openImportedItemWhenFinished: Bool,
        quickAccessFileToDismiss: QuickAccessFile?,
        onImported: (([Item]) -> Void)? = nil,
        onFinished: (([Item]) -> Void)? = nil,
        navigatesWhenFinished: Bool = true,
        confirmationOverride: ((Int) -> String)? = nil,
        summary: ((Int, [String]) -> Void)? = nil
    ) async {
        // What this import saved, set once `onImported` has run; `onFinished` hears it, or an empty list on any failure (#4044).
        var landed: [Item] = []
        defer {
            sourceImportTask = nil
            sourceImportProgressMessage = nil
            if refreshQuickFolderWhenFinished {
                refreshQuickAccessFolder()
            }
            onFinished?(landed)
        }
        do {
            let saved = try result.get()
            let store = try requireStore()
            let imported = saved.imported
            let failures = saved.failures
            guard !imported.isEmpty else {
                if !saved.rawFailures.isEmpty { diagnostics["recentFailure"] = saved.rawFailures.joined(separator: "\n") }
                // A pick that held a transcript says what happened in its own banner (#2997).
                if let summary {
                    summary(0, failures.map(Self.failedFileName(in:)))
                    return
                }
                reportFailure(failures.isEmpty ? "No source files were imported." : failures.joined(separator: "\n\n"))
                return
            }
            // The Library and the opened item are read off the main actor, as the EPUB and audiobook imports do.
            _ = try await reloadLibraryRowsOffMain(store: store)
            if navigatesWhenFinished {
                if openImportedItemWhenFinished, let item = imported.first {
                    let detail = try await loadItemDetailOffMain(id: item.id, store: store)
                    activeItemId = item.id
                    selectedItem = detail
                    screen = .item
                } else if saved.preservesActiveSession {
                    var preservedDetail: ItemDetailState?
                    if !saved.preservedSelectedItemId.isEmpty {
                        preservedDetail = try await loadItemDetailOffMain(id: saved.preservedSelectedItemId, store: store)
                    }
                    // The listener may have opened another item while the read ran: then there is nothing to restore.
                    if activeItemId == saved.preservedActiveItemId, selectedItem.id == saved.preservedSelectedItemId,
                       let preservedDetail {
                        selectedItem = preservedDetail
                    }
                } else {
                    let openedId = imported.first?.id ?? activeItemId
                    let detail = try await loadItemDetailOffMain(id: openedId, store: store)
                    activeItemId = openedId
                    selectedItem = detail
                    screen = .home
                }
            }
            if let quickAccessFileToDismiss {
                dismissQuickAccessFile(quickAccessFileToDismiss)
            }
            onImported?(imported)
            landed = imported
            imported.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.id) }
            if let structure = imported.compactMap(\.documentStructure).last {
                recordPDFExtractionDiagnostics(structure)
            }
            diagnostics["lastObsidianImportCount"] = "\(imported.count)"
            diagnostics["lastObsidianImportFailures"] = "\(failures.count)"
            markOnboardingSteps([.addedOwnSource, .addedFromFiles])
            if let summary {
                summary(imported.count, failures.map(Self.failedFileName(in:)))
                return
            }
            let suffix = failures.isEmpty ? "" : " \(failures.count) failed."
            reportConfirmation(confirmationOverride?(imported.count) ?? "Imported \(imported.count) source file\(imported.count == 1 ? "" : "s").\(suffix)")
        } catch {
            // The transcripts this pick already added still get their banner before the failure (#2997).
            summary?(0, [])
            reportFailure(error, context: "File import failed")
        }
    }

    /// A failure entry reads "file name", a line break, then the reason; the name is the first line.
    nonisolated static func failedFileName(in failure: String) -> String {
        failure.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? failure
    }

    func reportImportFailure(_ error: Error) {
        reportFailure(error, context: "File import failed")
    }
}
