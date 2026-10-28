import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
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
        navigatesWhenFinished: Bool = true,
        confirmationOverride: ((Int) -> String)? = nil
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

        sourceImportTask = Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                await Self.prepareObsidianImports(requests)
            }.value
            scopedAccess.forEach { entry in
                if entry.didAccess {
                    entry.url.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            // The writes stay on the main actor under their hang label; the reads after them do not (#2505).
            let saved = self.hangTelemetry.labels.scoped("obsidianImportFinish") {
                Result { try self.completeObsidianMarkdownImport(batch) }
            }
            await self.finishObsidianMarkdownImport(
                saved,
                refreshQuickFolderWhenFinished: refreshQuickFolderWhenFinished,
                openImportedItemWhenFinished: openImportedItemWhenFinished,
                quickAccessFileToDismiss: quickAccessFileToDismiss,
                onImported: onImported,
                navigatesWhenFinished: navigatesWhenFinished,
                confirmationOverride: confirmationOverride
            )
        }
    }

    private nonisolated static func prepareObsidianImports(_ requests: [ObsidianImportRequest]) async -> ObsidianImportBatch {
        var prepared: [PreparedObsidianImport] = []
        var failures: [String] = []
        var rawFailures: [String] = []
        for request in requests {
            do {
                let imported = try await importableText(from: request.url)
                prepared.append(try SourceFileItemBuilder.prepare(
                    imported, fileURL: request.url, itemId: request.itemId, createdAt: Date()
                ))
            } catch {
                failures.append("\(request.url.lastPathComponent)\n\(ListenerErrorText.message(for: error))")
                rawFailures.append("\(request.url.lastPathComponent): \(error)")
            }
        }
        return ObsidianImportBatch(prepared: prepared, failures: failures, rawFailures: rawFailures)
    }

    private nonisolated static func importableText(from url: URL) async throws -> ImportedSourceText {
        guard url.pathExtension.lowercased() == "pdf" else {
            return ImportedSourceText(
                text: try String(contentsOf: url, encoding: .utf8),
                documentStructure: nil
            )
        }
        #if canImport(PDFKit)
        do {
            let extracted = try NativePDFDocumentExtractor.extractStructured(from: url)
            return ImportedSourceText(
                text: extracted.document.text,
                documentStructure: extracted.documentStructure,
                structuredDocument: extracted.document,
                title: extracted.title
            )
        } catch PDFStructuredTextExtractor.ExtractionError.noExtractableText {
            throw SourceFileImportError.pdfHasNoExtractableText
        }
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
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

    private func completeObsidianMarkdownImport(_ batch: ObsidianImportBatch) throws -> SavedObsidianBatch {
        let store = try requireStore()
        var saved = SavedObsidianBatch(
            imported: [], failures: batch.failures, rawFailures: batch.rawFailures,
            preservesActiveSession: hasActiveSession && engine != nil,
            preservedActiveItemId: activeItemId, preservedSelectedItemId: selectedItem.id)
        for prepared in batch.prepared {
            do {
                try store.saveItem(prepared.item)
                if let listeningMap = prepared.listeningMap {
                    try store.saveListeningMap(listeningMap)
                }
                if let document = prepared.structuredDocument {
                    try store.saveStructuredDocument(document, itemId: prepared.item.id)
                }
                saved.imported.append(prepared.item)
            } catch {
                saved.failures.append("\(prepared.item.title)\n\(ListenerErrorText.message(for: error))")
                saved.rawFailures.append("\(prepared.item.title): \(error)")
            }
        }
        if !saved.imported.isEmpty, engine == nil {
            installEngine(try makeEngine(store: store))
        }
        return saved
    }

    private func finishObsidianMarkdownImport(
        _ result: Result<SavedObsidianBatch, Error>,
        refreshQuickFolderWhenFinished: Bool,
        openImportedItemWhenFinished: Bool,
        quickAccessFileToDismiss: QuickAccessFile?,
        onImported: (([Item]) -> Void)? = nil,
        navigatesWhenFinished: Bool = true,
        confirmationOverride: ((Int) -> String)? = nil
    ) async {
        defer {
            sourceImportTask = nil
            sourceImportProgressMessage = nil
            if refreshQuickFolderWhenFinished {
                refreshQuickAccessFolder()
            }
        }
        do {
            let saved = try result.get()
            let store = try requireStore()
            let imported = saved.imported
            let failures = saved.failures
            guard !imported.isEmpty else {
                reportFailure(failures.isEmpty ? "No source files were imported." : failures.joined(separator: "\n\n"))
                if !saved.rawFailures.isEmpty { diagnostics["recentFailure"] = saved.rawFailures.joined(separator: "\n") }
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
                    activeItemId = saved.preservedActiveItemId
                    if let preservedDetail { selectedItem = preservedDetail }
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
            imported.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.id) }
            if let structure = imported.compactMap(\.documentStructure).last {
                recordPDFExtractionDiagnostics(structure)
            }
            diagnostics["lastObsidianImportCount"] = "\(imported.count)"
            diagnostics["lastObsidianImportFailures"] = "\(failures.count)"
            markOnboardingSteps([.addedOwnSource, .addedFromFiles])
            let suffix = failures.isEmpty ? "" : " \(failures.count) failed."
            reportConfirmation(confirmationOverride?(imported.count) ?? "Imported \(imported.count) source file\(imported.count == 1 ? "" : "s").\(suffix)")
        } catch {
            reportFailure(error, context: "File import failed")
        }
    }

    func reportImportFailure(_ error: Error) {
        reportFailure(error, context: "File import failed")
    }
}
