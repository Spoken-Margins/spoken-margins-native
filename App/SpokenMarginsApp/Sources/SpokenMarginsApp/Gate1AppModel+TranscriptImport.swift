import Foundation
import SessionKit
import SessionKitEPUB
import SessionKitPersistence

/// Meeting transcripts picked from Files or the Quick Folder (#2997). The rule that decides what a file is, and every
/// sentence, live in SessionKit (`TranscriptPickImport`, `TranscriptPickBanner`); this is the model's thin call.
extension Gate1AppModel {
    /// Where a pick goes after the transcript rule has looked at it, and what the text import does when it finishes.
    struct TranscriptPickRoute {
        var securityScopedURLs: [URL]
        var refreshQuickFolderWhenFinished = false
        var openImportedItemWhenFinished = false
        var quickAccessFileToDismiss: QuickAccessFile?
    }

    /// Imports a pick of document files. A `.vtt`, `.srt`, `.docx` or `.txt` goes through the transcript rule first;
    /// whatever it does not take (a `.txt` that isn't a transcript, `.md`, `.pdf`) goes to the text import as before,
    /// with that import's own words when no file was a transcript.
    ///
    /// The whole pick runs as one import task under `sourceImportTask`, so a second pick while it runs gets today's
    /// "Another source is already importing." Nothing here navigates, except the Quick Folder's "Add and open".
    func importFilesWithTranscriptRule(urls: [URL], route: TranscriptPickRoute) {
        guard urls.contains(where: TranscriptPickImport.isCandidate) else {
            importPickAsText(urls, route: route, summary: nil)
            return
        }
        guard sourceImportTask == nil else {
            reportFailure("Another source is already importing. You can keep using playback while it finishes.")
            return
        }
        let store: SQLiteSessionStore
        do { store = try requireStore() } catch {
            reportFailure(error, context: "File import failed")
            return
        }
        let scopedAccess = route.securityScopedURLs.map { url in (url: url, didAccess: url.startAccessingSecurityScopedResource()) }
        sourceImportProgressMessage = urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) files…"
        statusMessage = sourceImportProgressMessage ?? "Importing sources…"
        lastError = nil
        let stillListening = engine?.itemIdsStillListening ?? []
        let pickedCount = urls.count

        sourceImportTask = Task { [weak self] in
            // Reading, parsing and the store write run off the main actor, one file after another.
            let picked = await Task.detached(priority: .userInitiated) { () async -> Result<TranscriptPickImport.Result, Error> in
                do {
                    return .success(try await TranscriptPickImport.run(
                        urls: urls, store: store, docxText: { try DocxPlainText.text(from: $0) },
                        stillListeningItemIds: stillListening))
                } catch {
                    return .failure(error)
                }
            }.value
            // Access stays open until the finish has handed any leftover files to the text import, which starts its
            // own; the counts nest, so both balance.
            defer { scopedAccess.forEach { entry in if entry.didAccess { entry.url.stopAccessingSecurityScopedResource() } } }
            guard let self else { return }
            // The Library is read off the main actor, as the other file imports do (#2505).
            var reloadError: Error?
            if case .success(let result) = picked, !result.added.isEmpty {
                do { try await self.reloadLibraryRowsOffMain(store: store) } catch { reloadError = error }
            }
            let itemToOpen = self.hangTelemetry.labels.scoped("transcriptImportFinish") {
                self.finishTranscriptImport(picked, reloadError: reloadError, store: store, pickedCount: pickedCount, route: route)
            }
            if let itemToOpen { await self.openImportedTranscript(itemId: itemToOpen, store: store) }
        }
    }

    private func importPickAsText(_ files: [URL], route: TranscriptPickRoute, summary: ((Int, [String]) -> Void)?) {
        beginObsidianMarkdownImport(
            urls: files, securityScopedURLs: route.securityScopedURLs,
            refreshQuickFolderWhenFinished: route.refreshQuickFolderWhenFinished,
            openImportedItemWhenFinished: route.openImportedItemWhenFinished,
            quickAccessFileToDismiss: route.quickAccessFileToDismiss,
            summary: summary)
    }

    /// Everything after the Library has been reloaded, on the main actor and in one stretch. Returns the item to open
    /// when the pick asked to ("Add and open"), for the caller to load off the main actor.
    private func finishTranscriptImport(
        _ picked: Result<TranscriptPickImport.Result, Error>, reloadError: Error?, store: SQLiteSessionStore,
        pickedCount: Int, route: TranscriptPickRoute
    ) -> String? {
        var releasedSlot = false
        func releaseImportSlot() {
            guard !releasedSlot else { return }
            releasedSlot = true
            sourceImportTask = nil
            sourceImportProgressMessage = nil
        }
        defer { releaseImportSlot() }
        do {
            let result = try picked.get()
            guard result.handledAnyTranscript else {
                // No file was a transcript: today's import, with today's words.
                releaseImportSlot()
                importPickAsText(result.passthrough, route: route, summary: nil)
                return nil
            }
            if let reloadError { throw reloadError }
            if !result.added.isEmpty {
                if engine == nil { installEngine(try makeEngine(store: store)) }
                markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                result.added.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.itemId) }
                diagnostics["lastTranscriptImportCount"] = "\(result.added.count)"
                if let file = route.quickAccessFileToDismiss { dismissQuickAccessFile(file) }
            }
            if route.refreshQuickFolderWhenFinished { refreshQuickAccessFolder() }
            let added = result.added.map { (itemId: $0.itemId, title: $0.title) }
            if result.passthrough.isEmpty {
                reportTranscriptPick(added: added, refusals: result.refusals, documentsImported: 0, documentFailureNames: [], pickedCount: pickedCount)
            } else {
                // The rest of the pick goes to the text import, which tells this banner how many it added and what failed.
                releaseImportSlot()
                importPickAsText(result.passthrough, route: route) { [weak self] imported, failedNames in
                    self?.reportTranscriptPick(
                        added: added, refusals: result.refusals, documentsImported: imported,
                        documentFailureNames: failedNames, pickedCount: pickedCount)
                }
            }
            return route.openImportedItemWhenFinished ? result.added.first?.itemId : nil
        } catch {
            reportFailure(error, context: "File import failed")
            return nil
        }
    }

    /// The Quick Folder's "Add and open": the listener asked to open it, so the item's screen opens.
    private func openImportedTranscript(itemId: String, store: SQLiteSessionStore) async {
        do {
            let detail = try await loadItemDetailOffMain(id: itemId, store: store)
            activeItemId = itemId
            selectedItem = detail
            screen = .item
        } catch {
            reportFailure(error, context: "File import failed")
        }
    }

    /// The one banner a pick leaves once a file in it was handled as a transcript.
    private func reportTranscriptPick(
        added: [(itemId: String, title: String)], refusals: [TranscriptImportMessage],
        documentsImported: Int, documentFailureNames: [String], pickedCount: Int
    ) {
        switch TranscriptPickBanner.make(
            added: added, refusals: refusals, documentsImported: documentsImported,
            documentFailureNames: documentFailureNames, pickedCount: pickedCount
        ) {
        case .addedOne(let itemId, let title): reportAddedToLibrary(title: title, itemId: itemId)
        case .confirmation(let words): reportConfirmation(words)
        case .failure(let words): reportFailure(words)
        }
    }
}
